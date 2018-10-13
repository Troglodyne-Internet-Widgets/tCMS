<?php
    $args = ( $_SERVER['REQUEST_METHOD'] == 'POST' ? $_POST : $_GET );
    $user_info = posix_getpwuid(posix_geteuid());
    // Probably the 'sanest' default I could think of when you have no homedir
    $dir = ( $user_info['dir'] ? $user_info['dir'] : '/var/www/' );
    $basedir = ( file_exists( $dir . "/.tCMS_basedir") ? file_get_contents("$dir/.tCMS_basedir") : "$dir/.tCMS" );
    if( !empty($args['app']) && $args['app'] == 'login' ) {
        include("login.inc");
        die();
    } elseif( !empty($args['app']) && $args['app'] == 'logout' ) {
        include("logout.inc");
        die();
    } else {
        include_once("$basedir/lib/auth.inc");
        $auth = new auth;
        $auth->ensure_auth();
    }
    if( empty($args['app']) || $args['app'] == 'config' ) {
        $kontent = "settings.inc";
    } elseif ($args['app'] == 'blog') {
        $kontent = "bengine.inc";
    } elseif ($args['app'] == 'microblog') {
        $kontent = "mbengine.inc";
    } elseif ($args['app'] == 'users' ) {
        $kontent = "users.inc";
    } else {
        $kontent = "settings.inc";
    }
?>
<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <meta charset="utf-8" />
  <meta name="description" content="tCMS Control Panel"/>
  <meta name="viewport" content="width=device-width">
  <link rel="stylesheet" type="text/css" href="../../css/structure.css" />
  <link rel="stylesheet" type="text/css" href="../../css/screen.css" media="screen" />
  <link rel="stylesheet" type="text/css" href="../../css/print.css" media="print" />
  <?php
    if(file_exists('../../css/custom/avatars.css')) {
      echo '<link rel="stylesheet" type="text/css" href="../../css/custom/avatars.css" />';
    } else {
      echo '<link rel="stylesheet" type="text/css" href="../../css/avatars.css" />';
    }
  ?>
  <link rel="icon" type="image/vnd.microsoft.icon" href="../../img/icon/favicon.ico" />
  <title>tCMS Admin</title>
  <?php
   $config = @json_decode(@file_get_contents("$basedir/config/main.json"),true);
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
