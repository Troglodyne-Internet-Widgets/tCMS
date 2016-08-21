<?php
$protocol = ( !empty($_SERVER["HTTPS"] ) ) ? 'https'       : 'http';
$nav      = ( !empty($_GET['nav'] ) )      ? $_GET['nav']  : '';
$post     = ( !empty($_GET['post'] ) )     ? $_GET['post'] : '';

if(file_exists('sys/admin/config/main.json')) {
	$config = json_decode(file_get_contents('sys/admin/config/main.json'),true);
} else {
	# XXX Need to have manual be hosted in repo under sys/admin/manual
	include( "templates/default/notconfigured.tmpl" );
	die();
}
?>
<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <meta charset="utf-8" />
  <meta name="description" content="A Simple CMS by teodesian.net"/>
  <meta name="viewport" content="width=device-width">
  <link rel="stylesheet" type="text/css" href="css/structure.css" />
  <link rel="stylesheet" type="text/css" href="css/screen.css" media="screen" />
  <link rel="stylesheet" type="text/css" href="css/print.css" media="print" />
  <?php
    if(file_exists('css/custom/avatars.css')) {
      echo '<link rel="stylesheet" type="text/css" href="css/custom/avatars.css" />';
    } else {
      echo '<link rel="stylesheet" type="text/css" href="css/avatars.css" />';
    }
  ?>
  <!--Compatibility Stylesheets-->
  <!--[if lte IE 8]>
   <link rel="stylesheet" type="text/css" href="css/compat/ie.css">
  <![endif]-->
  <!--[if lte IE 7]>
   <link rel="stylesheet" type="text/css" href="css/compat/ie6-7.css">
  <[endif]-->
  <!--[if IE 6]>
   <link rel="stylesheet" type="text/css" href="css/compat/ie6.css">
  <![endif]-->
  <?php
    if(file_exists('css/custom/screen.css')) {
      echo '<link rel="stylesheet" type="text/css" href="css/custom/screen.css" />';
    }
    if(file_exists('css/custom/print.css')) {
      echo '<link rel="stylesheet" type="text/css" href="css/custom/print.css" />';
    }
    if(file_exists('favicon.ico')) {
      echo '<link rel="icon" type="image/vnd.microsoft.icon" href="favicon.ico" />';
    } else {
      echo '<link rel="icon" type="image/vnd.microsoft.icon" href="img/icon/favicon.ico" />';
    }
  ?>
  <title>
   <?php
    echo $config['htmltitle'];
   ?>
  </title>
 </head>
 <body>
  <div id="topkek">
   <?php
    //Site's Titlebar comes in here
    include $config['toptitle'];
   ?>
  </div>
  <div id="littlemenu">
  </div>
  <div id="kontainer">
   <div id="leftbar" class="kontained">
    <?php
     include $config['leftbar'];
    ?>
   </div>
   <div id="kontent" class="kontained">
   <?php
/*$kontent basically is just a handler for what PHP include needs to be loaded
based on the context passed via GET params - if you wanna add another, add an
elseif case then specify the next number in the nav index along with the
corresponding file to include above.*/
$destinations = [
	$config['home'], $config['fileshare'], $config['microblog'], $config['blog'], $config['about'],
	$config['postloader'], $config['codeloader'], $config['audioloader'], $config['videoloader'],
	$config['imgloader'], $config['docloader']
];
if ( empty($nav) ) $nav = 0;
if ( $nav === 1 || $nav > 5 ) {
	$pwd = $post;
	include 'sys/fileshare/sanitize.inc';
}
$kontent = $destinations[$nav];
//Main Content Display Frame goes below
include $kontent;
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
