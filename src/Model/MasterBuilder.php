<?php

namespace Model;

use Core\Config;
use Core\Database\DB;
use Game\Buildings\BuildingHelper;
use Game\Formulas;
use Game\GoldHelper;
use Game\ResourcesHelper;
use function logError;

class MasterBuilder
{
    public function process($row)
    {
        $db = DB::getInstance();
        ResourcesHelper::updateVillageResources($row['kid'], true);
        $village = $db->query("SELECT capital, upkeep, isWW, pop, owner, kid, wood, woodp, clay, clayp, iron, ironp, crop, cropp, maxstore, maxcrop, lastmupdate FROM vdata WHERE kid={$row['kid']}");
        if (!$village->num_rows) {
            $db->query("DELETE FROM building_upgrade WHERE kid={$row['kid']}");
            //logError("MasterBuilder: Village does not exist.");
            return;
        }
        $village = $village->fetch_assoc();
        $player = $db->query("SELECT aid, race, gift_gold, bought_gold, plus FROM users WHERE id={$village['owner']} LIMIT 1");
        if (!$player->num_rows) {
            $db->query("DELETE FROM building_upgrade WHERE kid={$row['kid']}");
            //logError("MasterBuilder: Player does not exist.");
            return;
        }
        $player = $player->fetch_assoc();
        $buildings = $this->sortBuildings($row['kid']);
        $item_id = $buildings['buildings'][$row['building_field']]['item_id'];
        $level = $buildings['buildings'][$row['building_field']]['level'] + 1;
        $level += (int) $db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE isMaster=0 AND building_field={$row['building_field']} AND kid={$row['kid']}");
        $costs = Formulas::buildingUpgradeCosts($item_id, $level);
        $workers = $this->isWorkersBusy(
            $player['race'],
            $player['plus'] >= time(),
            $row['kid'],
            $row['building_field'] <= 18,
            $item_id == 40
        );
        if ($workers['isBusy']) {
            //logError("MasterBuilder: Workers were busy.");
            return;
        }
        //ignore  ww here
        if ($item_id <> 40) {
            if (!$this->isResourcesAvailable($village, $costs)) {
                //maybe a server lag!
                //logError("MasterBuilder: Resources not available.");
                return;
            }
        }
        $db->query("DELETE FROM building_upgrade WHERE id={$row['id']}");
        if ($item_id <> 40) {
            $gold = Config::getInstance()->gold->masterBuilderGold;
            if (($player['gift_gold'] + $player['bought_gold']) < $gold) {
                $db->query("DELETE FROM building_upgrade WHERE isMaster=1 AND kid={$row['kid']}");
                logError('MasterBuilder: Not enough gold.');
                return;
            } else if ($gold > 0 && !GoldHelper::decreaseGold($village['owner'], $gold)) {
                $db->query("DELETE FROM building_upgrade WHERE isMaster=1 AND kid={$row['kid']}");
                logError('MasterBuilder: Unable to reduce gold.');
                return;
            }
            //TODO: level 0 buildings when building level 1
        }
        $kid = $row['kid'];
        $commence = $row['commence'];
        if ($player['race'] == 1) {
            if ($item_id > 4 && $workers['buildsNum'] > 0) {
                $commence = $this->getLastCommence($kid, false);  // inside slot
            } else if ($item_id <= 4 && $workers['fieldsNum'] > 0) {
                $commence = $this->getLastCommence($kid, true);   // outside slot
            }
        } else {
            $commence = $this->getLastCommence($kid);
        }
        $commence += Formulas::buildingUpgradeTime($item_id, $level, $buildings['mainBuildingLevel'], $village['isWW']);
        $db->query("INSERT INTO building_upgrade (`kid`, `building_field`, `isMaster`, start_time, `commence`) VALUES ({$row['kid']},{$row['building_field']},0," . time() . ",$commence)");
        if ($item_id <> 40) {
            $db->query("UPDATE vdata SET wood=wood-{$costs[0]}, clay=clay-{$costs[1]}, iron=iron-{$costs[2]}, crop=crop-{$costs[3]} WHERE kid={$row['kid']}");
        }
    }

    public function processNext($kid)
    {
        $db = DB::getInstance();
        ResourcesHelper::updateVillageResources($kid, true);

        $village = $db->query("SELECT capital, upkeep, isWW, pop, owner, kid, wood, woodp, clay, clayp, iron, ironp, crop, cropp, maxstore, maxcrop, lastmupdate FROM vdata WHERE kid=$kid");
        if (!$village->num_rows) {
            $db->query("DELETE FROM building_upgrade WHERE kid=$kid AND isMaster=1");
            return;
        }
        $village = $village->fetch_assoc();

        $player = $db->query("SELECT aid, race, gift_gold, bought_gold, plus FROM users WHERE id={$village['owner']} LIMIT 1");
        if (!$player->num_rows) {
            $db->query("DELETE FROM building_upgrade WHERE kid=$kid AND isMaster=1");
            return;
        }
        $player = $player->fetch_assoc();

        $buildings = $this->sortBuildings($kid);
        $config = Config::getInstance();
        $gold = $village['isWW'] ? 0 : $config->gold->masterBuilderGold;

        // Fetch ALL master items for this village in FIFO order.
        // We iterate once; for each item we check if its slot is currently free
        // and resources are available. isWorkersBusy() reads live DB state, so
        // after we promote an item the slot count updates correctly for the next item.
        $masterItems = $db->query("SELECT * FROM building_upgrade WHERE isMaster=1 AND kid=$kid ORDER BY id ASC");

        while ($row = $masterItems->fetch_assoc()) {
            $item_id = $buildings['buildings'][$row['building_field']]['item_id'];
            $isField = ($row['building_field'] <= 18);

            $workers = $this->isWorkersBusy(
                $player['race'],
                $player['plus'] >= time(),
                $kid,
                $isField,
                $item_id == 40
            );

            // Slot for this item type is full — skip this item, keep looking.
            if ($workers['isBusy']) {
                continue;
            }

            $level = $buildings['buildings'][$row['building_field']]['level'] + 1;
            $level += (int) $db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE isMaster=0 AND building_field={$row['building_field']} AND kid=$kid");

            // Resources check — skip this item if unaffordable, try next.
            if ($item_id != 40) {
                $costs = Formulas::buildingUpgradeCosts($item_id, $level);
                if (!$this->isResourcesAvailable($village, $costs)) {
                    continue;
                }
            }

            // Gold check — hard stop, clear entire queue.
            if ($item_id != 40) {
                if (($player['gift_gold'] + $player['bought_gold']) < $gold) {
                    $db->query("DELETE FROM building_upgrade WHERE isMaster=1 AND kid=$kid");
                    logError('MasterBuilder: Not enough gold.');
                    return;
                } else if ($gold > 0 && !GoldHelper::decreaseGold($village['owner'], $gold)) {
                    $db->query("DELETE FROM building_upgrade WHERE isMaster=1 AND kid=$kid");
                    logError('MasterBuilder: Unable to reduce gold.');
                    return;
                }
            }

            // Promote.
            $db->query("DELETE FROM building_upgrade WHERE id={$row['id']}");

            $commence = time();
            if ($player['race'] == 1) {
                if (!$isField && $workers['buildsNum'] > 0) {
                    $commence = $this->getLastCommence($kid, false);
                } else if ($isField && $workers['fieldsNum'] > 0) {
                    $commence = $this->getLastCommence($kid, true);
                }
            } else {
                $commence = $this->getLastCommence($kid);
            }
            $commence += Formulas::buildingUpgradeTime($item_id, $level, $buildings['mainBuildingLevel'], $village['isWW']);

            $db->query("INSERT INTO building_upgrade (kid, building_field, isMaster, start_time, commence) VALUES ($kid, {$row['building_field']}, 0, " . time() . ", $commence)");

            if ($item_id != 40) {
                $costs = Formulas::buildingUpgradeCosts($item_id, $level);
                $db->query("UPDATE vdata SET wood=wood-{$costs[0]}, clay=clay-{$costs[1]}, iron=iron-{$costs[2]}, crop=crop-{$costs[3]} WHERE kid=$kid");
                // Refresh resources in memory so subsequent iterations see updated amounts.
                $village['wood'] -= $costs[0];
                $village['clay'] -= $costs[1];
                $village['iron'] -= $costs[2];
                $village['crop'] -= $costs[3];
            }

            // Continue the loop — there may be another free slot (e.g. Romans with
            // both field and build slots open) that a later item can fill.
        }

        $this->updateCommence($kid, false);
    }

    private function getLastCommence($kid, ?bool $isField = null)
    {
        $db = DB::getInstance();
        $filter = '';
        if ($isField === true)
            $filter = ' AND building_field <= 18';
        if ($isField === false)
            $filter = ' AND building_field > 18';
        $commence = $db->fetchScalar("SELECT commence FROM building_upgrade WHERE kid=$kid AND isMaster=0{$filter} ORDER BY commence DESC LIMIT 1");
        return $commence !== false ? (int) $commence : time();
    }

    private function sortBuildings($kid)
    {
        $db = DB::getInstance();
        $buildings_db = $db->query("SELECT * FROM fdata WHERE kid={$kid}")->fetch_assoc();
        $whole_village_buildings = [];
        $mainBuildingLevel = 0;
        for ($i = 1; $i <= 40; $i++) {
            $whole_village_buildings[$i] = [
                'item_id' => $buildings_db['f' . $i . 't'],
                'level' => $buildings_db['f' . $i],
            ];
            if ($whole_village_buildings[$i]['item_id'] == 15) {
                $mainBuildingLevel = $whole_village_buildings[$i]['level'];
            }
        }
        $whole_village_buildings[99] = [
            'item_id' => $buildings_db['f99t'],
            'level' => $buildings_db['f99'],
        ];
        return [
            'buildings' => $whole_village_buildings,
            'mainBuildingLevel' => $mainBuildingLevel,
        ];
    }

    private function isWorkersBusy($race, $hasPlus, $kid, $isField, $isWW)
    {
        $db = DB::getInstance();
        $workers = ['fieldsNum' => 0, 'buildsNum' => 0];
        $stmt = $db->query("SELECT building_field FROM building_upgrade WHERE isMaster=0 AND kid=$kid");
        while ($row = $stmt->fetch_assoc()) {
            ++$workers[$row['building_field'] <= 18 ? 'fieldsNum' : 'buildsNum'];
        }
        $maxTasks = $hasPlus ? 2 : 1; //its with wonder
        if ($isWW) {
            $maxTasks = 2;
        }
        if ($race == 1) {
            return [
                'fieldsNum' => $workers['fieldsNum'],
                'buildsNum' => $workers['buildsNum'],
                'isBusy' => (($isField) ? ($workers['fieldsNum'] >= $maxTasks) : ($workers['buildsNum'] >= $maxTasks)) || ($workers['fieldsNum'] + $workers['buildsNum']) >= 3,
                'isPlusUsed' => ($hasPlus ? ($isField ? ($workers['fieldsNum'] > 0) : ($workers['buildsNum'] > 0)) : FALSE),
            ];
        }
        return [
            'fieldsNum' => $workers['fieldsNum'],
            'buildsNum' => $workers['buildsNum'],
            'isBusy' => ($workers['buildsNum'] + $workers['fieldsNum']) >= $maxTasks,
            'isPlusUsed' => ($hasPlus ? (($workers['buildsNum'] + $workers['fieldsNum']) > 0) : FALSE),
        ];
    }

    private function isResourcesAvailable($current_resources, $costs)
    {
        $current_resources = [
            $current_resources['wood'],
            $current_resources['clay'],
            $current_resources['iron'],
            $current_resources['crop'],
        ];
        foreach ($costs as $k => $v) {
            if ($v > floor($current_resources[$k])) {
                return false;
            }
        }

        return true;
    }

    public function updateCommence($kid, $update = true, $simple = false)
    {
        $maxTime = time() + 100 * 86400;
        $helper = new BuildingHelper();
        $db = DB::getInstance();
        $villageModel = new VillageModel();
        $masterBuilders = $db->query("SELECT * FROM building_upgrade WHERE isMaster=1 AND kid={$kid} ORDER BY id");
        if (!$masterBuilders->num_rows) {
            return false;
        }
        $village = $db->query("SELECT capital, upkeep, isWW, pop, owner, kid, wood, woodp, clay, clayp, iron, ironp, crop, cropp, maxstore, maxcrop, lastmupdate FROM vdata WHERE kid=$kid");
        if (!$village->num_rows) {
            return false;
        }
        $village = $village->fetch_assoc();
        $player = $db->query("SELECT aid, race, plus FROM users WHERE id={$village['owner']} LIMIT 1");
        if (!$player->num_rows) {
            return false;
        }
        if ($update) {
            ResourcesHelper::updateVillageResources($kid, $simple);
        }
        $player = $player->fetch_assoc();
        $buildings = $this->sortBuildings($kid);
        if (!$village['isWW']) {
            $wwLevel = -1;
        } else {
            $onLoadLevels = (int) $db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE isMaster=0 AND building_field=99 AND kid=$kid");
            $wwLevel = $buildings['buildings'][99]['level'] + (int) $onLoadLevels;
        }

        // Romans have two independent worker slots (fields outside / builds inside),
        // so we track a separate scheduling chain for each.
        // All other races have one shared slot.
        $isRoman = ($player['race'] == 1);
        $previous_commence_fields = 0; // accumulator for building_field <= 18 (outside)
        $previous_commence_builds = 0; // accumulator for building_field >  18 (inside)

        $queryBatch = [];
        while ($row = $masterBuilders->fetch_assoc()) {
            $item_id = $buildings['buildings'][$row['building_field']]['item_id'];
            $level = $buildings['buildings'][$row['building_field']]['level'] + 1;
            $level += (int) $db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE isMaster=0 AND building_field={$row['building_field']} AND kid=$kid");
            $cu = Formulas::buildingCropConsumption($item_id, $level, $village['isWW']);

            // Determine which chain this item belongs to
            $isField = ($row['building_field'] <= 18);
            if ($isRoman) {
                $previous_commence = $isField ? $previous_commence_fields : $previous_commence_builds;
            } else {
                $previous_commence = $previous_commence_fields; // single shared chain for non-Romans
            }

            $commence = time() + $previous_commence;

            if ($level > Formulas::buildingMaxLvl($item_id, $village['capital'])) {
                $this->deleteProcess($row['id'], $kid, $row['building_field'], $level);
                continue;
            }
            if (
                $row['building_field'] > 18 && $level == 1 && $helper->canCreateNewBuild(
                    $village['capital'],
                    $player['race'],
                    $item_id,
                    $buildings['buildings'],
                    true
                ) <> 1
            ) {
                $this->deleteProcess($row['id'], $kid, $row['building_field'], $level);
                continue;
            }
            if (
                $helper->checkArtifactDependencies(
                    $player['aid'],
                    $village['owner'],
                    $kid,
                    $item_id,
                    $village['isWW'],
                    $wwLevel
                ) <> 0
            ) {
                $this->deleteProcess($row['id'], $kid, $row['building_field'], $level);
                continue;
            }
            $freeCrop = $village['cropp'] + $village['upkeep'] - $this->getCropLoading($row['kid'], $village['isWW'], $buildings['buildings']);
            if (
                $helper->checkDependencies(
                    $item_id,
                    $level,
                    $village['isWW'],
                    $freeCrop,
                    $village['maxstore'],
                    $village['maxcrop']
                ) <> 0
            ) {
                $this->deleteProcess($row['id'], $kid, $row['building_field'], $level);
                continue;
            }
            $workers = $this->isWorkersBusy(
                $player['race'],
                $player['plus'] >= time(),
                $row['kid'],
                $item_id <= 4,
                $item_id == 40
            );
            if ($workers['isBusy']) {
                // For Romans, only look at active builds in the same slot (inside vs outside).
                // For others, look at all active builds.
                if ($isRoman) {
                    $slotFilter = $isField ? ' AND building_field <= 18' : ' AND building_field > 18';
                } else {
                    $slotFilter = '';
                }
                $end_time = $db->fetchScalar("SELECT commence FROM building_upgrade WHERE isMaster=0 AND kid={$row['kid']}{$slotFilter} ORDER BY commence ASC LIMIT 1");
                if ($end_time > $commence) {
                    $commence += (int) $end_time - time();
                }
            }
            // ignore WW here cuz it's not actually master and we got the resources first.
            if ($item_id <> 40) {
                $cost = Formulas::buildingUpgradeCosts($item_id, $level);
                if (!$this->isResourcesAvailable($village, $cost)) {
                    $commence += $this->calcualteAvailable($village, $cost);
                }
            }
            if ($commence <> $row['commence']) {
                // check outrange
                if ($commence > $maxTime) {
                    $commence = $maxTime;
                }
                $queryBatch[] = "UPDATE building_upgrade SET commence={$commence} WHERE id={$row['id']}";
            }

            // Advance the correct chain
            $elapsed = $commence - time();
            if ($isRoman) {
                if ($isField) {
                    $previous_commence_fields += $elapsed;
                } else {
                    $previous_commence_builds += $elapsed;
                }
            } else {
                $previous_commence_fields += $elapsed;
            }
        }
        if (sizeof($queryBatch)) {
            foreach ($queryBatch as $query) {
                $db->query($query);
            }
        }
    }

    private function deleteProcess($processId, $wid, $building_field, $level)
    {
        $db = DB::getInstance();
        if ($level == 1 && $building_field > 18 && $building_field < 99) {
            $db->query("UPDATE fdata SET f{$building_field}t=0 WHERE kid=" . $wid);
        }

        return $db->query("DELETE FROM building_upgrade WHERE id=" . $processId);
    }

    private function getCropLoading($kid, $isWW, $buildings)
    {
        $db = DB::getInstance();
        $upgrades = $db->query("SELECT building_field FROM building_upgrade WHERE isMaster=0 AND kid=" . $kid);
        if (!$upgrades->num_rows) {
            return 0;
        }
        $cu = 0;
        $tmp = [];
        while ($row = $upgrades->fetch_assoc()) {
            if (!isset($tmp[$row['building_field']])) {
                $tmp[$row['building_field']] = 0;
            }
            ++$tmp[$row['building_field']];
            $level = $buildings[$row['building_field']]['level'] + $tmp[$row['building_field']];
            $cu += Formulas::buildingCropConsumption($buildings[$row['building_field']]['item_id'], $level, $isWW);
        }

        return $cu;
    }

    private function calcualteAvailable($data, $costs)
    {
        //TODO: i don't know how they calculate minus crop in master builder but no problem we set to update every day
        // resources are not valid! calculate resources until end of plus and again further!
        $timeNeeded = 0;
        $cur_res = [$data['wood'], $data['clay'], $data['iron'], $data['crop']];
        $cur_prod = [
            $data['woodp'],
            $data['clayp'],
            $data['ironp'],
            $data['cropp'],
        ];
        for ($i = 0; $i < 4; ++$i) {
            if (floor($cur_res[$i]) < $costs[$i]) {
                if ($i == 3 && $cur_prod[$i] <= 0) {
                    $neededTime = 86400;
                } else {
                    $neededTime = ($costs[$i] - floor($cur_res[$i])) / $cur_prod[$i] * 3600000;
                }
                if ($neededTime > $timeNeeded) {
                    $timeNeeded = $neededTime;
                }
            }
        }

        return floor($timeNeeded / 1000);
    }
}