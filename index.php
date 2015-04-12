<!doctype html>
<html dir="ltr" lang="en-US">
 <head>
  <?php
   //SRSBIZNUSS below - you probably shouldn't edit this unless you know what you are doing
   //GET validation/sanitation and parameter variable definitions below
   if (!empty($_SERVER["HTTPS"])) {
    $protocol = "http";
   } else {
    $protocol = "https";
   }
   if (empty($_GET['nav'])) {
    $nav = '';
   }
   else {
    $nav = $_GET['nav'];
   }
   if (empty($_GET['post'])) {
    $post = '';
   }
   else {
    $post = $_GET['post'];
   }

   //input sanitization
   $pwd=$post;
   include 'sys/fileshare/sanitize.inc';
   if ($san == 1) {
    return(0);
   };
   extract(json_decode(file_get_contents('sys/admin/config/main.json'),true));
  ?>
  <meta charset="utf-8" />
  <meta name="description" content="A Simple CMS by teodesian.net"/>
  <meta name="viewport" content="width=device-width">
  <link rel="stylesheet" type="text/css" href="css/structure.css" />
  <link rel="stylesheet" type="text/css" href="css/screen.css" media="screen" />
  <link rel="stylesheet" type="text/css" href="css/print.css" media="print" />
  <link rel="stylesheet" type="text/css" href="css/avatars.css" />
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
  <link rel="icon" type="image/vnd.microsoft.icon" href="img/icon/favicon.ico" />
  <title>
   <?php
    echo $htmltitle;
   ?>
  </title>
 </head>
 <body>
  <div id="topkek">
   <?php
    //Site's Titlebar comes in here
    include $toptitle;
   ?>
  </div>
  <div id="littlemenu">
  </div>
  <div id="kontainer">
   <div id="leftbar" class="kontained">
    <?php
     include $leftbar;
    ?>
   </div>
   <div id="kontent" class="kontained">
    <?php
      /*$kontent basically is just a handler for what PHP include needs to be loaded
      based on the context passed via GET params - if you wanna add another, add an
      elseif case then specify the next number in the nav index along with the
      corresponding file to include above.*/
      if (empty($nav)) {
        $kontent = $home;
      }
      elseif ($nav == 1) {
        $kontent = $fileshare;
      }
      elseif ($nav == 2) {
        $kontent = $microblog;
        $editable = 0;
      }
      elseif ($nav == 3) {
        $kontent = $blog;
      }
      elseif ($nav == 4) {
        $kontent = $about;
      }
      elseif ($nav == 5) {
        $kontent = $postloader;
      }
      elseif ($nav == 6) {
        $kontent = $codeloader;
      }
      elseif ($nav == 7) {
        $kontent = $audioloader;
      }
      elseif ($nav == 8) {
        $kontent = $videoloader;
      }
      elseif ($nav == 9) {
        $kontent = $imgloader;
      }
      elseif ($nav == 10) {
        $kontent = $docloader;
      }
      //Main Content Display Frame goes below
      include $kontent;
    ?>
   </div>
   <div id="rightbar" class="kontained">
    <?php
     include $rightbar;
    ?>
   </div>
  </div>
   <div id="footbar">
    <?php
     include $footbar;
    ?>
   </div>
 </body>
</html>
