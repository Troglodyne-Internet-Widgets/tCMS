<?php
if (!empty($_SERVER['REMOTE_USER']) && $_SERVER['REMOTE_USER'] == "admin") {
    $poster = "admin";
} else {
    $poster = "Nobody";
}
?>
