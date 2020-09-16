<?php
$tcmsUsers = json_decode(file_get_contents('config/users.json'),true);
if (!empty($_SERVER['REMOTE_USER']) && !empty($tcmsUsers)) {
    $poster = "admin";
    foreach (array_keys($tcmsUsers) as $user) {
        if( $tcmsUsers[$user]['remoteUser'] == $_SERVER['REMOTE_USER']) {
            $poster = $user;
            break;
        }   
    }   
} else {
    $poster = "Nobody";
}
?>
