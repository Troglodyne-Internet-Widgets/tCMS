<?php
# Get protocol bits, etc.
$protocol = ( !empty($_SERVER["HTTPS"] ) ) ? 'https'       : 'http';
$nav      = ( !empty($_GET['nav'] ) )      ? $_GET['nav']  : '';
$post     = ( !empty($_GET['post'] ) )     ? $_GET['post'] : '';
$docroot  = $_SERVER['DOCUMENT_ROOT'];

# Grab the main configuration file. We need to see where that lives first though.
if( file_exists( "$docroot/basedir" ) ) {
    $fh = fopen( "$docroot/basedir" );
    $basedir = trim(fgets( $fh )); # I only want the first line
    fclose($fh);
} else {
    $basedir = posix_getpwuid(posix_geteuid())['dir'] . "/.tCMS";
}

if(!file_exists("$basedir/conf/main.json")) {
	# XXX Need to have manual be hosted in repo under sys/admin/manual
	include( "$basedir/templates/default/notconfigured.tmpl" );
	die();
}
$config = json_decode(file_get_contents("$basedir/conf/main.json"),true);
// Not sure if I'll ever really even need to localize (see html tag attrs).
?>
<!doctype html>
<html dir="ltr" lang="en-US">
 <?php include("$basedir/templates/" . $config['theme'] . "/header.tmpl"); ?>
 <body>
  <div id="topkek">
   <?php
    //Site's Titlebar comes in here
    include("$basedir/templates/" . $config['theme'] . "/nav.inc");
   ?>
  </div>
  <div id="littlemenu">
  </div>
  <div id="kontainer">
   <div id="leftbar" class="kontained">
    <?php include $config['leftbar']; ?>
   </div>
   <div id="kontent" class="kontained">
   <?php
    //XXX fileshare, etc. shouldn't be a config value. Home should refer to a template.
    $destinations = [
        $config['home'], $config['fileshare'], $config['microblog'], $config['blog'], $config['postloader'],
        $config['codeloader'], $config['audioloader'], $config['videoloader'], $config['imgloader'],
        $config['docloader']
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
     include $config['rightbar'];
    ?>
   </div>
  </div>
   <div id="footbar">
    <?php
     include $config['footbar'];
    ?>
   </div>
 </body>
</html>
