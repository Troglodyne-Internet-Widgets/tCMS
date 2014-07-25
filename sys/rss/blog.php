<?php
	extract(json_decode(file_get_contents('../admin/config/main.json'),true));
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
	echo "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n";
	echo "<channel>\n";
    $atomlink = "http://".$_SERVER["SERVER_NAME"]."/".$basedir.$rssdir."blog.php";
	echo "<atom:link href=\"".$atomlink."\" rel=\"self\" type=\"application/rss+xml\" />";
	echo "\t<title>".$htmltitle."</title>\n";
	echo "\t<description>".$blogtitle."</description>\n";
	echo "\t<link>http://".$_SERVER["SERVER_NAME"]."/".$basedir."</link>\n";

	$tiem = date(DATE_RFC2822, time());

	echo "\t<lastBuildDate>$tiem</lastBuildDate>\n";
	echo "\t<pubDate>$tiem</pubDate>\n";

	$files = glob($_SERVER["DOCUMENT_ROOT"]."/".$basedir.$blogdir."*.post");
	$guid = count($files);

	//sort by filename
	
	//initialize an array to house sort results
	$files2 = array();
	$files2 = array_pad($files2,$guid,0);

	for ($i=0; $i<$guid; $i++) {
		$j = explode('-',basename($files[$i]));
		$j = $j[0];
		$j = (int)$j;
		$j--;
		$files2[$j] = $files[$i];
	}

	$slen = count($files2)-1;
	$ctr = 0;

		for ($i=$slen; $i>-1; $i--) {
			$shitpost=$files2[$i];
		
			if ($ctr > 9) {break;};
			$ctr++;

                	$statz = stat($shitpost);
                	$uid = $statz['uid'];
                	$udata = posix_getpwuid($uid);
                	$user = $udata['name'];

                	$date =  date(DATE_RFC2822, filemtime($shitpost));

                	$title = substr(strstr(basename($shitpost),'-'),1,-5);
			$contents = file_get_contents($shitpost);

			echo "\t<item>\n";
               		echo "\t\t<title>$title</title>\n";
                	echo "\t\t<description><![CDATA[".$contents."]]>\t\t</description>\n";
			echo "\t\t<link>http://teodesian.net/index.php?nav=8&amp;post=".$shitpost."</link>\n";
			echo "\t\t<guid isPermaLink=\"false\">$guid-teodesian.net</guid>\n";
			echo "\t\t<pubDate>".$date."</pubDate>\n";
			echo "\t\t<author>".$user."</author>\n";
			echo "\t</item>\n";
			$guid--;
		}
	echo "</channel>\n";
	echo "</rss>";
?>
