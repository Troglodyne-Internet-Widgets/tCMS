<?php
  //Import your config, set some stuff up, then construct the mining laser
  extract(json_decode(file_get_contents('../admin/config/main.json'),true));
  extract(json_decode(file_get_contents('../admin/config/users.json'),true));
  date_default_timezone_set($timezone);
  $tiem = date(DATE_RSS);
  $today = date("m.d.y");
  $atomlink = "http://".$_SERVER["SERVER_NAME"]."/".$basedir.$rssdir."microblog.php";
  $newsdir = $_SERVER["DOCUMENT_ROOT"]."/".$basedir.$microblogdir;
  $files = glob($newsdir.$today."/*");
  $slen = count($files);
  $feed = '<?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
	     <channel>
	      <atom:link href="'.$atomlink.'" rel="self" type="application/rss+xml" />
	      <title>'.$htmltitle.'</title>
	      <description>'.$microblogtitle.' RSS Feed</description>
	      <link>http://'.$_SERVER['SERVER_NAME'].'/'.$basedir.'</link>
	      <lastBuildDate>'.$tiem.'</lastBuildDate>
	      <pubDate>'.$tiem.'</pubDate>';
  foreach ($files as $shitpost) {
    $storyPubDate =  date(DATE_RSS, strtotime(basename($shitpost)));
    $contents = file_get_contents($shitpost);
    //HAHAHA You thought you needed an XML parser, didn't you?
    $theRipper = explode("<",$contents);
    $theRipper = explode(">",$theRipper[2]);
    $storyTitle = $theRipper[1];
    $theRipper = explode('"',$theRipper[0]);
    $storyLink = htmlspecialchars($theRipper[1]);
    $theRipper = explode("</h3>",$contents);
    $theRipper = explode("<hr />",$theRipper[1]);
    $storyText = $theRipper[0];
    $theRipper = explode("title=\"Posted by ",$contents);
    $theRipper = explode('"',$theRipper[1]);
    $poster = $theRipper[0];
    $email = "null@example.com";
    $author = "X";
    if(isset($tcmsUsers[$poster])) {
        $email = $tcmsUsers[$poster]["email"];
        $author = $tcmsUsers[$poster]["fullName"]; 
    }
    $feed .= '<item>
               <title>'.$storyTitle.'</title>
               <description><![CDATA['.$storyText.']]></description>
               <link>'.$storyLink.'</link>
               <guid isPermaLink="false">'.basename($shitpost).'-'.$_SERVER["SERVER_NAME"].'</guid>
               <pubDate>'.$storyPubDate.'</pubDate>
               <author>'.$email.' ('.$author.')</author>
              </item>';
  }
  $feed .= ' </channel>
            </rss>';
  print_r($feed);
?>
