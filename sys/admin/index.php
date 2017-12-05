<?php
    include_once("lib/auth.inc");
	auth::ensure_auth();
    if( empty($_GET['app']) || $_GET['app'] == 'config' ) {
        $kontent = "settings.inc";
    } elseif ($_GET['app'] == 'blog') {
        $kontent = "bengine.inc";
    } elseif ($_GET['app'] == 'microblog') {
        $kontent = "mbengine.inc";
    } elseif ($_GET['app'] == 'users' ) {
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
   $config = json_decode(file_get_contents('config/main.json'),true);
  ?>
 </head>
 <body>
  <div id="topkek" style="text-align: center; vertical-align: middle;">
   <button title="Menu" id="clickme">&#9776;</button>
   <span id="configbar">
    <a class="topbar" title="Edit Various Settings" href="index.php">Settings</a>
    <a class="topbar" title="Blog Writer" href="index.php?nav=1">Blog Writer</a>
    <a class="topbar" title="Pop off about Stuff" href="index.php?nav=2">MicroBlogger</a>
   </span>
  </div>
  <div id="kontent" style="display: block;">
   <?php
        include $kontent;
   ?>
  </div>
 </body>
</html>
