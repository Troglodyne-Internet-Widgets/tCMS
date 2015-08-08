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

    //input sanitization - XXX Why is this in the index? Should only be include in stuff that needs it
    $pwd=$post;
    include 'sys/fileshare/sanitize.inc';
    if ($san == 1) {
      return(0);
    };
    if(file_exists('sys/admin/config/main.json')) {
      $config = json_decode(file_get_contents('sys/admin/config/main.json'),true);
    } else {
      # XXX Need to have manual be hosted in repo under sys/admin/manual
      echo "</head><body>tCMS has not gone through initial configuration.<br />";
      echo 'Please see the <a href="https://tcms.troglodyne.net/index.php?nav=5&post=fileshare/manual/Chapter%2000-Introduction.post">tCMS Manual</a> for how to accomplish this.';
      die("</body></html>");
    }
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
      if (empty($nav)) {
        $kontent = $config['home'];
      }
      elseif ($nav == 1) {
        $kontent = $config['fileshare'];
      }
      elseif ($nav == 2) {
        $kontent = $config['microblog'];
        $editable = 0;
      }
      elseif ($nav == 3) {
        $kontent = $config['blog'];
      }
      elseif ($nav == 4) {
        $kontent = $config['about'];
      }
      elseif ($nav == 5) {
        $kontent = $config['postloader'];
      }
      elseif ($nav == 6) {
        $kontent = $config['codeloader'];
      }
      elseif ($nav == 7) {
        $kontent = $config['audioloader'];
      }
      elseif ($nav == 8) {
        $kontent = $config['videoloader'];
      }
      elseif ($nav == 9) {
        $kontent = $config['imgloader'];
      }
      elseif ($nav == 10) {
        $kontent = $config['docloader'];
      }
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
