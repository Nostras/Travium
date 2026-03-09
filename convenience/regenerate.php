<?php
header('Content-Type: text/plain');

require dirname(__DIR__) . "/include/env.php";
require SRC_PATH_DEV . "/bootstrap.php";
require dirname(__DIR__) . "/include/connection.php";
if (file_exists(dirname(__DIR__) . "/include/config.custom.php")) {
    require dirname(__DIR__) . "/include/config.custom.php";
}

global $connection, $config;

$mysqli = new mysqli(
    $connection['database']['hostname'],
    $connection['database']['username'],
    $connection['database']['password'],
    $connection['database']['database']
);

$targetSpeed = $config->game->speed;
echo "Starting Full Economy & Culture Refresh\n";
echo "Target Speed: " . $targetSpeed . "x\n";
echo "-------------------------------------------\n";

// 1. Get all villages and their owners
$res = $mysqli->query("SELECT kid, owner FROM vdata WHERE isFarm = 0 AND owner > 0");
$villages = [];
$uniqueUsers = [];

while ($row = $res->fetch_assoc()) {
    $villages[] = $row;
    $uniqueUsers[$row['owner']] = true;
}

echo "Found " . count($villages) . " villages and " . count($uniqueUsers) . " players.\n";

// 2. Instantiate Model for Resource Update
$model = new \Model\VillageModel();

// 3. Process Culture Points (Per Village)
echo "Recalculating Culture Points...\n";
foreach ($villages as $v) {
    // Calling the static method we found in your grep
    \Model\VillageModel::calculateVillageCulturePointsAndPopulation($v['kid']);
}

// 4. Process Resources (Per User)
echo "Recalculating Resource Production...\n";
foreach (array_keys($uniqueUsers) as $uid) {
    $model->updateUserVillageResources($uid, false);
}

$mysqli->close();
echo "-------------------------------------------\n";
echo "SUCCESS: Economy and CP refreshed to " . $targetSpeed . "x.\n";
