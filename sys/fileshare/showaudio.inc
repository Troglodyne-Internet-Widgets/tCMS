<?php
//Listen to audio -- ONLY MP3s IN THIS HOUSE
//$title = basename($post);
 $tag = id3_get_tag($post);
 $date =  date("F d Y H:i:s", filemtime($post));
 $parent = dirname($post);
 echo "<h3><a class=nudes title=permalink href=\"$post\">".$tag["title"]."</a></h3>";
 echo "By: ".$tag["artist"]."<br />";
 echo "$date UTC<br/ >";
 echo "<p id=\"audioplayer_1\">Alternative content</p>";
 echo "<script type=\"text/javascript\">\n";
 echo "AudioPlayer.embed(\"audioplayer_1\", {soundFile: \"".$protocol."://teodesian.net/".$post."\"});\n";
 echo "</script><br />\n";
 echo "Description:<br />";
 echo $tag["comment"];
 echo "<a title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=".$icondir."tsfolder-up.gif />$parent</a><hr />";
?>
