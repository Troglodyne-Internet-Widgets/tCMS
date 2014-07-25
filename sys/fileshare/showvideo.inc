<?php
//watch movies -- Only OGV is supported
$parent = dirname($post);
echo "<a title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=".$icondir."tsfolder-up.gif /></a>$parent<hr />";
$title = basename($post);
echo "<h3 class=blogtitles><a title=permalink href=\"$post\">".$title."</a></h3>";
echo "<video src=\"".$post."\" type=\"video/ogg\" codecs=\"theora, vorbis\" controls=\"controls\" width=\"100%\" height=\"80%\" poster=\"img/sys/testpattern.jpg\">";
echo "<applet code=\"com.fluendo.player.Cortado.class\" archive=\"sys/fileshare/video/cortado.jar\" width=\"100%\" height=\"80%\">";
echo "<param name=\"url\" value=\"http://teodesian.net/".$post."\"/>\n";
echo "<param name='bufferSize' value='4096'>\n";
echo "<param name='bufferHigh' value='25'>\n";
echo "<param name='bufferLow' value='5'>\n";
echo "<param name='autoPlay' value='false'>\n";
echo "<param name='statusHeight' value='20'>\n";
echo "Install the Java Plugin, or Enable Scripts to see video here.<br />";
echo "Or, <a href=\"".$post."\">download the video.\n";
echo "</applet>";
echo "</video>";
?>
