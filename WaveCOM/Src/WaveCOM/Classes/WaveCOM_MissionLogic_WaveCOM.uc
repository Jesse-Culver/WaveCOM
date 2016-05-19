class WaveCOM_MissionLogic_WaveCOM extends XComGameState_MissionLogic config(WaveCOM);

var config bool REFILL_ITEM_CHARGES;

enum eWaveStatus
{
	eWaveStatus_Preparation,
	eWaveStatus_Combat,
};

var eWaveStatus WaveStatus;
var int CombatStartCountdown;
var int WaveNumber;

struct WaveEncounter {
	var name EncounterID;
	var int Earliest;
	var int Latest;
	var int Weighting;

	structdefaultproperties
	{
		Earliest = 0
		Latest = 1000
		Weighting = 1
	}
};

var const config int WaveCOMKillSupplyBonusBase;
var const config float WaveCOMKillSupplyBonusMultiplier;
var const config int WaveCOMWaveSupplyBonusBase;
var const config float WaveCOMWaveSupplyBonusMultiplier;
var const config int WaveCOMPassiveXPPerKill;
var const config array<int> WaveCOMPodCount;
var const config array<int> WaveCOMForceLevel;
var const config array<WaveEncounter> WaveEncounters;

delegate EventListenerReturn OnEventDelegate(Object EventData, Object EventSource, XComGameState GameState, Name EventID);

function SetupMissionStartState(XComGameState StartState)
{
	`log("WaveCOM :: Setting Up State");
}

function RegisterEventHandlers()
{	
	`log("WaveCOM :: Setting Up Event Handlers");
	OnAlienTurnBegin(Countdown);
	OnNoPlayableUnitsRemaining(HandleTeamDead);
}

function UpdateCombatCountdown()
{
	if (WaveStatus == eWaveStatus_Preparation)
	{
		ModifyMissionTimer(true, CombatStartCountdown, "Prepare", "Next Wave in", Bad_Red);
	}
	else
	{
		ModifyMissionTimer(true, WaveNumber, "Wave Number", "In Progress"); // hide timer
	}
}

function EventListenerReturn Countdown(Object EventData, Object EventSource, XComGameState GameState, Name EventID)
{
	local XComGameStateHistory History;
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Item ItemState;
	local array<XComGameState_Item> ItemStates;
	local XComGameState_Unit UnitState;

	if (WaveStatus == eWaveStatus_Preparation)
	{

		CombatStartCountdown = CombatStartCountdown - 1;
		`log("WaveCOM :: Counting Down - " @ CombatStartCountdown);

		History = `XCOMHISTORY;
	
		NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Collect Wave Loot during Preparation");
		XComHQ = XComGameState_HeadquartersXCom(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom'));
		XComHQ = XComGameState_HeadquartersXCom(NewGameState.CreateStateObject(class'XComGameState_HeadquartersXCom', XComHQ.ObjectID));
		NewGameState.AddStateObject(XComHQ);

		// recover loot collected during preparation turns
		foreach History.IterateByClassType(class'XComGameState_Unit', UnitState)
		{
			if( UnitState.GetTeam() == eTeam_XCom)
			{
				UnitState = XComGameState_Unit(NewGameState.CreateStateObject(class'XComGameState_Unit', UnitState.ObjectID));
				NewGameState.AddStateObject(UnitState);
				ItemStates = UnitState.GetAllItemsInSlot(eInvSlot_Backpack, NewGameState);
				foreach ItemStates(ItemState)
				{
					ItemState.OwnerStateObject = XComHQ.GetReference();
					UnitState.RemoveItemFromInventory(ItemState, NewGameState);
					XComHQ.PutItemInInventory(NewGameState, ItemState, false);
				}
			}
		}
		`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);

		if (CombatStartCountdown == 0)
		{
			InitiateWave();
		}

		UpdateCombatCountdown();
	}
	return ELR_NoInterrupt;
}

function InitiateWave()
{
	local XComGameStateHistory History;
	local XComGameState_BattleData BattleData;
	local XComGameState_HeadquartersAlien AlienHQ;
	local XComGameState NewGameState;
	local array<WaveEncounter> WeightedStack;
	local WaveCOM_NonstackingReinforcements Spawner;
	local WaveEncounter Encounter;
	local int Pods, Weighting, ForceLevel;
	local Vector ObjectiveLocation;

	History = `XCOMHISTORY;
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Update Force Level");

	WaveStatus = eWaveStatus_Combat;
	WaveNumber = WaveNumber + 1;

	BattleData = XComGameState_BattleData(History.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	ObjectiveLocation = BattleData.MapData.ObjectiveLocation;
	BattleData = XComGameState_BattleData(NewGameState.CreateStateObject(class'XComGameState_BattleData', BattleData.ObjectID));

	if (WaveNumber > WaveCOMForceLevel.Length - 1)
	{
		ForceLevel = WaveCOMForceLevel[WaveCOMForceLevel.Length - 1];
	}
	else
	{
		ForceLevel = WaveCOMForceLevel[WaveNumber];
	}
	ForceLevel = Clamp(ForceLevel, 1, 20);

	AlienHQ = XComGameState_HeadquartersAlien(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersAlien'));
	AlienHQ.ForceLevel = ForceLevel;
	NewGameState.AddStateObject(AlienHQ);

	BattleData.SetForceLevel(ForceLevel);
	`SPAWNMGR.ForceLevel = ForceLevel;
	NewGameState.AddStateObject(BattleData);
	
	if (WaveNumber > WaveCOMPodCount.Length - 1)
	{
		Pods = WaveCOMPodCount[WaveCOMPodCount.Length - 1];
	}
	else
	{
		Pods = WaveCOMPodCount[WaveNumber];
	}

	foreach WaveEncounters(Encounter)
	{
		if (Encounter.Earliest <= WaveNumber && Encounter.Latest >= WaveNumber && Encounter.Weighting > 0)
		{
			Weighting = Encounter.Weighting;
			while (Weighting > 0 )
			{
				WeightedStack.AddItem(Encounter);
				--Weighting;
			}
		}
	}

	`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);

	while (Pods > 0 )
	{
		Encounter = WeightedStack[Rand(WeightedStack.Length)];
		class'WaveCOM_NonstackingReinforcements'.static.InitiateReinforcements(
			Encounter.EncounterID,
			1, // FlareTimer
			true, // bUseOverrideTargetLocation,
			ObjectiveLocation, // OverrideTargetLocation, 
			40 // Spawn tiles offset
		);
		--Pods;
	}

	
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Force Reinforcement ForceLevel");
	foreach History.IterateByClassType(class'WaveCOM_NonstackingReinforcements', Spawner)
	{
		Spawner = WaveCOM_NonstackingReinforcements(NewGameState.CreateStateObject(class'XComGameState_AIReinforcementSpawner', Spawner.ObjectID));

		// Pod Selection is hidden inside native code, however this function seems to do the trick, so we'll go with this
		`SPAWNMGR.SelectPodAtLocation(Spawner.SpawnInfo, ForceLevel, 1);
		NewGameState.AddStateObject(Spawner);
	}

	`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);

	`XEVENTMGR.TriggerEvent('WaveCOM_WaveStart');
}

function HandleTeamDead(XGPlayer LosingPlayer)
{
	if (LosingPlayer.m_eTeam == eTeam_Alien)
	{
		BeginPreparationRound();
	}
	else if (LosingPlayer.m_eTeam == eTeam_XCom)
	{
		`TACTICALRULES.EndBattle(LosingPlayer, eUICombatLose_UnfailableGeneric, false);
	}
}

function CollectLootToHQ()
{
	local XComGameStateHistory History;
	local XComGameState NewGameState;
	local name EffectName;
	local XComGameState_Effect EffectState;
	local XComGameState_BattleData BattleData;
	local XComGameState_HeadquartersXCom XComHQ;
	local int LootIndex, SupplyReward, KillCount;
	local X2ItemTemplateManager ItemTemplateManager;
	local XComGameState_Item ItemState;
	local StateObjectReference AbilityReference;
	local array<XComGameState_Item> ItemStates;
	local X2ItemTemplate ItemTemplate;
	local XComGameState_Unit UnitState;

	local LootResults PendingAutoLoot;
	local Name LootTemplateName;
	local array<Name> RolledLoot;
	local int x;

	History = `XCOMHISTORY;
	
	KillCount = 0;
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Collect Wave Loot");
	XComHQ = XComGameState_HeadquartersXCom(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom'));
	XComHQ = XComGameState_HeadquartersXCom(NewGameState.CreateStateObject(class'XComGameState_HeadquartersXCom', XComHQ.ObjectID));
	NewGameState.AddStateObject(XComHQ);

	BattleData = XComGameState_BattleData(History.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	BattleData = XComGameState_BattleData(NewGameState.CreateStateObject(class'XComGameState_BattleData', BattleData.ObjectID));
	NewGameState.AddStateObject(BattleData);

	ItemTemplateManager = class'X2ItemTemplateManager'.static.GetItemTemplateManager();
	foreach History.IterateByClassType(class'XComGameState_Unit', UnitState)
	{

		if( UnitState.IsAdvent() || UnitState.IsAlien() )
		{
			if ( !UnitState.bBodyRecovered ) {
				class'X2LootTableManager'.static.GetLootTableManager().RollForLootCarrier(UnitState.GetMyTemplate().Loot, PendingAutoLoot);

				// repurpose bBodyRecovered as a way to determine whether we got the loot yet
				UnitState = XComGameState_Unit(NewGameState.CreateStateObject(class'XComGameState_Unit', UnitState.ObjectID));
				UnitState.bBodyRecovered = true;
				UnitState.RemoveUnitFromPlay(); // must be done in the name of performance
				NewGameState.AddStateObject(UnitState);
				++KillCount;

				if( PendingAutoLoot.LootToBeCreated.Length > 0 )
				{
					foreach PendingAutoLoot.LootToBeCreated(LootTemplateName)
					{
						ItemTemplate = ItemTemplateManager.FindItemTemplate(LootTemplateName);
						SupplyReward = SupplyReward + Round(ItemTemplate.TradingPostValue * WaveCOMKillSupplyBonusMultiplier);
						SupplyReward = SupplyReward + WaveCOMKillSupplyBonusBase;
						RolledLoot.AddItem(ItemTemplate.DataName);
					}

				}
				PendingAutoLoot.LootToBeCreated.Remove(0, PendingAutoLoot.LootToBeCreated.Length);
				PendingAutoLoot.AvailableLoot.Remove(0, PendingAutoLoot.AvailableLoot.Length);
			}
		}
	}

	foreach History.IterateByClassType(class'XComGameState_Unit', UnitState)
	{
		if( UnitState.GetTeam() == eTeam_XCom)
		{
			UnitState = XComGameState_Unit(NewGameState.CreateStateObject(class'XComGameState_Unit', UnitState.ObjectID));
			UnitState.AddXp(KillCount * WaveCOMPassiveXPPerKill);
			UnitState.bRankedUp = false; // reset ranking to prevent blocking of future promotions
			NewGameState.AddStateObject(UnitState);

			ItemStates = UnitState.GetAllItemsInSlot(eInvSlot_Backpack, NewGameState);
			foreach ItemStates(ItemState)
			{
				ItemState.OwnerStateObject = XComHQ.GetReference();
				UnitState.RemoveItemFromInventory(ItemState, NewGameState);
				XComHQ.PutItemInInventory(NewGameState, ItemState, false);
			}

		}
	}

	ItemTemplateManager = class'X2ItemTemplateManager'.static.GetItemTemplateManager();
	for( LootIndex = 0; LootIndex < RolledLoot.Length; ++LootIndex )
	{
		// create the loot item
		`log("Added Loot: " @RolledLoot[LootIndex]);
		ItemState = ItemTemplateManager.FindItemTemplate(
			RolledLoot[LootIndex]
		).CreateInstanceFromTemplate(NewGameState);
		NewGameState.AddStateObject(ItemState);

		// assign the XComHQ as the new owner of the item
		ItemState.OwnerStateObject = XComHQ.GetReference();

		// add the item to the HQ's inventory (false so it automatically goes to stack)
		XComHQ.PutItemInInventory(NewGameState, ItemState, false);
	}

	SupplyReward = SupplyReward + WaveCOMWaveSupplyBonusBase;
	SupplyReward = SupplyReward + Round(WaveNumber * WaveCOMWaveSupplyBonusMultiplier);

	ItemTemplate = ItemTemplateManager.FindItemTemplate('Supplies');
	ItemState = ItemTemplate.CreateInstanceFromTemplate(NewGameState);
	ItemState.Quantity = Round(SupplyReward);
	NewGameState.AddStateObject(ItemState);
	XComHQ.PutItemInInventory(NewGameState, ItemState, false);

	ItemTemplate = ItemTemplateManager.FindItemTemplate('EleriumCore');
	ItemState = ItemTemplate.CreateInstanceFromTemplate(NewGameState);
	ItemState.Quantity = 1;
	NewGameState.AddStateObject(ItemState);
	XComHQ.PutItemInInventory(NewGameState, ItemState, false);

	`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);

	// Reset Unit Abilities
	foreach History.IterateByClassType(class'XComGameState_Unit', UnitState)
	{
		if( UnitState.GetTeam() == eTeam_XCom)
		{
			NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Clean Unit State");
			UnitState = XComGameState_Unit(NewGameState.CreateStateObject(class'XComGameState_Unit', UnitState.ObjectID));
			NewGameState.AddStateObject(UnitState);
			`log("Cleaning and readding Abilities");
			foreach UnitState.Abilities(AbilityReference)
			{
				NewGameState.RemoveStateObject(AbilityReference.ObjectID);
			}

			for (x = 0; x < UnitState.AppliedEffectNames.Length; ++x)
			{
				EffectName = UnitState.AppliedEffectNames[x];
				EffectState = XComGameState_Effect( `XCOMHISTORY.GetGameStateForObjectID( UnitState.AppliedEffects[ x ].ObjectID ) );
				if (EffectState != None)
				{
					EffectState.GetX2Effect().UnitEndedTacticalPlay(EffectState, UnitState);
				}
				EffectState.RemoveEffect(NewGameState, NewGameState, true); //Cleansed
			}

			UnitState.Abilities.Remove(0, UnitState.Abilities.Length);
			`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);


			NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Refill Unit State");
			UnitState = XComGameState_Unit(NewGameState.CreateStateObject(class'XComGameState_Unit', UnitState.ObjectID));
			`TACTICALRULES.InitializeUnitAbilities(NewGameState, UnitState);

			if (UnitState.FindAbility('Phantom').ObjectID > 0)
			{
				UnitState.EnterConcealmentNewGameState(NewGameState);
			}
			NewGameState.AddStateObject(UnitState);
			XComGameStateContext_TacticalGameRule(NewGameState.GetContext()).UnitRef = UnitState.GetReference();
			`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);
		}
	}
}

function BeginPreparationRound()
{
	WaveStatus = eWaveStatus_Preparation;
	CombatStartCountdown = 3;
	CollectLootToHQ();
	UpdateCombatCountdown();
	`XEVENTMGR.TriggerEvent('WaveCOM_WaveEnd');
}

defaultproperties
{
	WaveStatus = eWaveStatus_Preparation
	CombatStartCountdown = 3
	WaveNumber = 0
}