<?php
//Browse text files (like code)
$statz = stat($post);
$uid = $statz['uid'];
$udata = posix_getpwuid($uid);
$user = $udata['name'];
$date =  date("F d Y H:i:s", filemtime($post));
$title = basename($post);
echo "<h3 class=\"blogtitles\"><a title=permalink href=\"$post\">$title</a></h3>\n";
echo "Last modified on $date UTC by $user<br /><br />\n";
$text = file_get_contents($post);

// Convert UTF-8 string to HTML entities
$text = mb_convert_encoding($text, 'HTML-ENTITIES',"UTF-8");
// Convert HTML entities into ISO-8859-1
$text = html_entity_decode($text,ENT_NOQUOTES, "ISO-8859-1");
// Convert characters > 127 into their hexidecimal equivalents
for($i = 0; $i < strlen($text); $i++) {
 $letter = $text[$i];
 $num = ord($letter);
 if($num>127) {
  $out .= "&#$num;";
 } elseif ($letter == "\n") {
  $out .= "<br />";
 } elseif ($letter == "\t") {
  $out .= "&#8194;&#8194;&#8194;&#8194;";
 } elseif ($letter == " ") {
  $out .= "&#8194;";
 } else {
  $out .=  $letter;
 }
}
echo $out;
$parent = dirname($post);
echo "<hr /><a title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=img/mime/tsfolder-up.gif />$parent</a>";
?>
