<?php

    // Setup includes to work right. Much of this is duped in Config.inc, but gotta get this info to include it, so..
    $user_info = posix_getpwuid(posix_geteuid());
    $dir = ( $user_info['dir'] ? $user_info['dir'] : '/var/www/' );
    $basedir = ( file_exists( $dir . "/.tCMS_basedir") ? file_get_contents("$dir/.tCMS_basedir") : "$dir/.tCMS" );
    set_include_path(get_include_path() . PATH_SEPARATOR . "$basedir/lib");
    require_once "tCMS/Config.inc";

    // Get the config, set the theme (also set the basedir so we don't have to fetch it again).
    $conf_obj = new Config;
    $conf_obj->set_base_dir($basedir);
    $config = $conf_obj->get();
    $theme = ( !array_key_exists( 'theme', $config ) || empty($config['theme']) ? 'default' : $config['theme'] );
    $themedir = "$basedir/templates/$theme";

    // Begin dispatch
    $args = ( $_SERVER['REQUEST_METHOD'] == 'POST' ? $_POST : $_GET );
    if( !empty($args['app']) && $args['app'] == 'login' ) {
        include "$themedir/admin/login.inc";
        die();
    } elseif( !empty($args['app']) && $args['app'] == 'logout' ) {
        include "$themedir/admin/logout.inc";
        die();
    } else {
        require_once "tCMS/Auth.inc";
        $auth = new Auth;
        $auth->ensure_auth();
    }
    if( empty($args['app']) || $args['app'] == 'config' ) {
        $kontent = "$themedir/admin/settings.inc";
    } elseif ($args['app'] == 'blog') {
        if(!empty($args['get_fragment'])) {
            # Need to sanitize
            $path = realpath("$basedir/blog/".$args['get_fragment']);
            if(strpos($path, "$basedir/blog") !== 0 ) die("Forbidden: Tried to load $path, but $basedir/blog is not the start of the real path.");
            die(file_get_contents("$basedir/blog/".$args['get_fragment']));
        }
        $kontent = "$themedir/admin/bengine.inc";
    } elseif ($args['app'] == 'microblog') {
        $kontent = "$themedir/admin/mbengine.inc";
    } elseif ($args['app'] == 'users' ) {
        $kontent = "$themedir/admin/users.inc";
    } else {
        $kontent = "$themedir/admin/settings.inc";
    }
?>
<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <meta charset="utf-8" />
  <meta name="description" content="tCMS Control Panel"/>
  <meta name="viewport" content="width=device-width">
  <?php
    $links  = '<link rel="stylesheet" type="text/css" href="../../themed/' . $theme . '/css/structure.css" />';
    $links .= '<link rel="stylesheet" type="text/css" href="../../themed/' . $theme . '/css/screen.css" media="screen" />';
    $links .= '<link rel="stylesheet" type="text/css" href="../../themed/' . $theme . '/css/print.css" media="print" />';
    $links .= '<link rel="icon" type="image/vnd.microsoft.icon" href="../../themed/' . $theme . '/img/icon/favicon.ico" />';
    echo $links;

    // TODO inject avatars these via style tags based on config
  ?>
  <title>tCMS Admin</title>
  <?php
  ?>
 </head>
 <body>
  <div id="topkek" style="text-align: center; vertical-align: middle;">
   <button title="Menu" id="clickme">&#9776;</button>
   <span id="configbar">
    <a class="topbar" title="Edit Various Settings" href="index.php?app=config">Settings</a>
    <a class="topbar" title="Blog Writer" href="index.php?app=blog">Blog Writer</a>
    <a class="topbar" title="Pop off about Stuff" href="index.php?app=microblog">MicroBlogger</a>
    <a class="topbar" title="Logout" href="index.php?app=logout">Logout</a>
   </span>
  </div>
  <div id="kontent" style="display: block;">
   <?php
        include $kontent;
   ?>
  </div>
 </body>
</html>
