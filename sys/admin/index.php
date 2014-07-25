<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <meta charset="utf-8" />
  <meta name="description" content="tCMS Control Panel"/>
  <link rel="stylesheet" type="text/css" href="../../css/structure.css" />
  <link rel="stylesheet" type="text/css" href="../../css/screen.css" media="screen" />
  <link rel="stylesheet" type="text/css" href="../../css/print.css" media="print" />
  <link rel="icon" type="image/vnd.microsoft.icon" href="../../img/icon/favicon.ico" />
  <title>tCMS Admin</title>
  <?php
   extract(json_decode(file_get_contents('config/main.json'),true));
  ?>
  <script src="/sys/admin/index.js"></script>
 </head>
 <body>
  <div id="topkek" style="text-align: center; vertical-align: middle;">
   <span id="configbar">
    <a class="topbar" title="Edit Various Settings" href="index.php">Settings</a>
    <a class="topbar" title="Blog Writer" href="index.php?nav=1">Blog Writer</a>
    <a class="topbar" title="Pop off about Stuff" href="index.php?nav=2">MicroBlogger</a>
   </span>
   <button style="display: none;" id="menubutton" onClick="showMenu();return false;">
    &#9776;
   </button>
  </div>
  <div id="littlemenu" style="display: none;">
  </div>
  <div id="kontent" style="display: block;">
   <?php
    if ($_SERVER["HTTPS"] != "") {
     $protocol = "https";
    } else {
     $protocol = "http";
    }
    $nav = $_GET['nav'];
    if (empty($nav)) {
     $kontent = "settings.inc";
    }
    elseif ($nav == 1) {
     $kontent = "bengine.inc";
    }
    elseif ($nav == 2) {
     $kontent = "mbengine.inc";
    }
    include $kontent;
   ?>
  </div>
 </body>
</html>
