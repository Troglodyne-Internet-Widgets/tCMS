<?php
    $user_info = posix_getpwuid(posix_geteuid());
    $homedir = ( $user_info['dir'] ? $user_info['dir'] : '/var/www' );
    $libdir = ( file_exists( "$homedir/.tCMS_basedir") ? file_get_contents("$homedir/.tCMS_basedir") . "/lib" : "$homedir/.tCMS/lib" );
    include_once("$libdir/auth.inc");
    auth::invalidate_auth();
    die();
?>
