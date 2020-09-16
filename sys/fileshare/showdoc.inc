<?php
// Using googgle docs until a decent PDF viewer actually exists
// PDFObject would be nice if it didn't require a browser plugin
$statz = stat($post);
$uid = $statz['uid'];
$udata = posix_getpwuid($uid);
$user = $udata['name'];
$date =  date("F d Y H:i:s", filemtime($post));
$title = basename($post);
$parent = dirname($post);
echo "<a title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=img/mime/tsfolder-up.gif />$parent</a><hr />";
echo "<h3 class=blogtitles><a title=permalink href=\"$post\">$title</a></h3>\n";
echo "<em class=blogdetail>Last modified on $date UTC by $user</em><br /><br />\n";
echo "<iframe src=\"http://docs.google.com/gview?url=http://teodesian.net/$post&embedded=true\" style=\"width:100%; min-height:500px;\" frameborder=\"0\"></iframe>";
?>
