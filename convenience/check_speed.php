<?php
require __DIR__ . "/include/env.php";
require SRC_PATH_DEV . "/bootstrap.php";
echo "Game Speed: " . $config->game->speed . "\n";
echo "Move Speed: " . $config->game->movement_speed_increase . "\n";
