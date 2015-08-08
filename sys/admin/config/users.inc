<?php
$tcmsUsers = json_decode(file_get_contents('config/users.json'),true)
if (!empty($_SERVER['REMOTE_USER']) && !empty($tcmsUsers)) {
    $poster = "admin";
    if(array_search($_SERVER['REMOTE_USER'], $tcmsUsers) == $_SERVER['REMOTE_USER']) {
      $poster = $key;
    }
} else {
    $poster = "Nobody";
}
?>
