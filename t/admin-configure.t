<?php
$basedir = realpath(dirname(__FILE__));
require_once("$basedir/lib/testmore/testmore.php");

plan(2);

require_ok("$basedir/../sys/admin/lib/configure.php");
$config = configure::get_config_values("$basedir/../sys/admin/config/main.json.example");
ok( $config, "configure::get_config_values for known file fetches OK");
#print_r( $config );
?>
