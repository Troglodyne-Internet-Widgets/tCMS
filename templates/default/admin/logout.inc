<?php
    require_once "tCMS/auth.inc";
    $auth = new Auth;
    $auth->invalidate_auth();
    die();
?>
