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

    if(empty($config)) {
        # XXX Need to have manual be hosted in repo under sys/admin/manual
        include( "$themedir/notconfigured.tmpl" );
        die();
    }

    $docroot  = realpath( __DIR__ );
    $nav      = ( !empty($_GET['nav'] ) )      ? $_GET['nav']  : '';
    $post     = ( !empty($_GET['post'] ) )     ? $_GET['post'] : '';

    // Not sure if I'll ever really even need to localize (see html tag attrs).
?>
<!doctype html>
<html dir="ltr" lang="en-US">
 <?php include "$themedir/header.tmpl"; ?>
 <body>
  <div id="topkek">
   <?php
    //Site's Titlebar comes in here
    include "$themedir/nav.inc";
   ?>
  </div>
  <div id="littlemenu">
  </div>
  <div id="kontainer">
   <div id="leftbar" class="kontained">
    <?php include "$themedir/leftbar.inc"; ?>
   </div>
   <div id="kontent" class="kontained">
   <?php
    // Home should refer to a template.
    $home = ( array_key_exists( 'home', $config ) && !empty($config['home']) ? $config['home'] : "$docroot/sys/blogroll.inc" );
    $destinations = [
        $config['home'], "$docroot/sys/fileshare/showfiles.inc", "$docroot/sys/microblog.inc",
        "$docroot/sys/blogroll.inc", "$docroot/sys/fileshare/showpost.inc", "$docroot/sys/fileshare/showcode.inc",
        "$docroot/sys/fileshare/showaudio.inc", "$docroot/sys/fileshare/showvideo.inc", "$docroot/sys/fileshare/showimg.inc",
        "$docroot/sys/fileshare/showdoc.inc",
    ];
    if ( empty($nav) ) $nav = 0;
    if ( $nav === 1 || $nav > 4 ) {
        $pwd = $post;
        include 'sys/fileshare/sanitize.inc';
    }
    //Main Content Display Frame goes below
    include $destinations[$nav];
   ?>
   </div>
   <div id="rightbar" class="kontained">
    <?php
     include "$themedir/rightbar.inc";
    ?>
   </div>
  </div>
   <div id="footbar">
    <?php
     include "$themedir/footbar.inc";
    ?>
   </div>
 </body>
</html>
