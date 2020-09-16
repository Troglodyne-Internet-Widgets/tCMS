<?php
//Generic .post file loader
if ($nav == 5 && file_exists($post)) {
 $statz = stat($post);
 $uid = $statz['uid'];
 $udata = posix_getpwuid($uid);
 $user = $udata['name'];
 $date =  date("F d Y H:i:s", filemtime($post));
 if (stristr($post,'.') != ".post") {
  $title = basename($post);
 } else {
  $title = strstr(basename($post),'.', true);
 }
 echo "<h3 class=\"blogtitles\"><a title=permalink href=\"index.php?nav=5&post=$post\">$title</a></h3>\n";
 echo "<em class=\"blogdetail\">Last modified on $date UTC by $user</em><br /><hr />\n";
 include "$post";
 $parent = dirname($post);
 echo "<hr /><a style=\"padding-left: auto; padding-right: auto;\" title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=img/mime/tsfolder-up.gif /></a>$parent";
}

//404 Loader for files specified in GET param that don't actually exist
elseif ($nav == 5 && !file_exists($post)) {echo "<h1 style=\"padding-left: auto; padding-right: auto;\">404 - Not Found</h1>";}
?>
