<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <meta charset="utf-8" />
  <meta name="description" content="tCMS Control Panel"/>
  <meta name="viewport" content="width=device-width">
  <link rel="stylesheet" type="text/css" href="../../css/structure.css" />
  <link rel="stylesheet" type="text/css" href="../../css/screen.css" media="screen" />
  <link rel="stylesheet" type="text/css" href="../../css/print.css" media="print" />
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
    if (!empty($_SERVER["HTTPS"])) {
     $protocol = "https";
    } else {
     $protocol = "http";
    }
    if (empty($_GET['nav'])) {
     $kontent = "settings.inc";
    }
    elseif ($_GET['nav'] == 1) {
     $kontent = "bengine.inc";
    }
    elseif ($_GET['nav'] == 2) {
     $kontent = "mbengine.inc";
    }
    include $kontent;
   ?>
  </div>
 </body>
</html>
