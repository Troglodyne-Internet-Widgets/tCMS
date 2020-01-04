<?php
    require_once "tCMS/Auth.inc";
    $auth = new Auth;
    $auth->invalidate_auth();
    die();
?>
