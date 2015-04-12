<?php
  if ($editable) { //Insert the Only JS the project should have, all it does is toggle a div
    echo "
      <script type=\"text/javascript\">
        function switchMenu(obj) {
          var el = document.getElementById(obj);
          if ( el.style.display != 'none' ) {
            el.style.display = 'none';
          }
          else {
            el.style.display = '';
	  }
        }
      </script>\n";
  }
  echo '<p class="title"><a title="RSS" class="rss" href="/'.$basedir.$rssdir.'microblog.php"></a> '.$microblogtitle;
  //Set important times - $tdtime is today's date, $oldtime is the oldest known date a tCMS install had nuze for - defaults to today then searches microblog dir for entries to set date
  $tdtime = new DateTime(null, new DateTimeZone($timezone));
  $oldtime = clone $tdtime;
  //limit results of directory read to first entry -- much faster than doing it with PHP once you get a large filelist. 
  exec("ls -tr1 ".$_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir." |head -1", $cmd_out);
  if(!empty($cmd_out[0])) {
    $oldtime = $oldtime = DateTime::createFromFormat('m.d.y', $cmd_out[0], new DateTimeZone($timezone));
  }
  $oldtime->sub(new DateInterval('P1D'));
  /*$today and $tmrw refer to times relative to what is passed by GET params -
  $today is the date requested by GET, $tmrw is bool designating whether $today is something other than $tdtime 
  error indicates whether you supplied a bogus GET param for date.*/
  $tmrw = 0;
  $error = 0;
  $today = clone $tdtime;
  if(!empty($_GET["date"])) {
    $today = DateTime::createFromFormat('m.d.y', $_GET["date"], new DateTimeZone ($timezone));
    //Catch bogus input, set $tmwr to TRUE if $today was set to something other than today's date
    if (!filter_var($_GET["date"],FILTER_VALIDATE_REGEXP,array('options' => array('regexp' => "/^(0[1-9]|1[012])[.](0[1-9]|[12][0-9]|3[01])[.]\d\d/")))) {
      echo "</p>That's a funny looking date you provided there, mister.\n";
      $error=1;
    }
    else if ($today > $tdtime) { //catch if day supplied by GET is IN THE FUTURE
      echo "</p>Welcome to the future<br /><img style=\"max-width:100%; padding-left: auto; padding-right: auto;\" src=\"http://gunshowcomic.com/comics/20090930.png\" />\n";
      $error=1;
    }   
    else if ($today < $tdtime) {
      $tmrw = 1;
    }
  }
  /*Catch if day in question has no news -
  If not, display day before (or before that if still no news.
  $oldtime used here to tell when to stop looping back)*/
  if (!$error) {
    while (empty($todaysnews)) {
      $todaysnews = ""; //Set it to be something empty to prevent logspam
      $yesterday = clone $today;//This may look strange, but it'll make sense later
      $tomorrow = clone $today;
      $tomorrow->add(new DateInterval('P1D'));
      $yesterday->sub(new DateInterval('P1D'));
      //Detect if We're at the end of postings
      if ($yesterday < $oldtime) {
        echo " (".$today->format('m.d.y')."):</p><hr />";
        echo "For me, it was a beginning, but for you it is the end of the road.<br /><hr />\n";
        if ($oldtime != $tdtime) {
          $tomorrow = clone $oldtime;
          $tomorrow->add(new DateInterval('P1D'));
	  $tomorrow = $tomorrow->format('m.d.y');
        }
        $todaysnews = "end";
      }
      if ($todaysnews != "end") {
        //Get news from directory if any exists for that day, glob will return empty if nothing is in dir
        $todaysnews = glob($_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir.$today->format('m.d.y')."/*");
        //Set display date for today's news, set $today to be yesterday in order to get while loop to recurse correctly
        $realtime = $today->format('m.d.y');
        if(!empty($_GET['fwd']) && $_GET['fwd']) {//Check whether we are traversing forward or backward in time
          $today = clone $tomorrow;
        } else { //Default to going back
          $today = clone $yesterday;
        }
        //Finish by setting times for Yesterday and Tomorrow so that they can be used in links below
        $tomorrow = clone $yesterday;
        $tomorrow->add(new DateInterval('P2D'));
        $tomorrow = $tomorrow->format('m.d.y');
        $yesterday = $yesterday->format('m.d.y');
      }
    }
    if ($todaysnews != "end") {
      echo " (".$realtime."):</p><hr />\n";
      foreach ($todaysnews as $i) {
        $fh = fopen($i,'r');
        $fc = fread($fh,10000); //If a microblog item is more than 1kb, you are doing something wrong.
        fclose($fh);
        $json = json_decode($fc);
        if(is_null($json)) {
          echo $fc;
        } elseif (!empty($json->title) && !empty($json->url) && !empty($json->poster)) {
          $out = '<h3 class="blogtitles">
                    <a href="'.$json->url.'">'.$json->title.'</a>
                    <a class="usericon '.$json->poster.'" title="Posted by '.$json->poster.'"></a>
                  </h3>';
          if(!empty($json->image)) {
            $out .= '<img class="mblogimg" src="'.$json->image.'" />';
          }
          if(!empty($json->audio)) {
            $out .= '<audio src="'.$json->audio.'" controls>
                       Download Audio 
                       <a href="'.$json->audio.'">Here</a><br />
                     </audio>';
          }
          if(!empty($json->video)) {
            $out .= '<video src="'.$json->video.'" controls>
                       Download Video
                       <a href="'.$json->video.'">Here</a><br />
                     </video>';
          }
          if(!empty($json->comment)) {
            $out .= $json->comment;
          }
          $out .= '<hr />';
          echo $out;
        } #Note that if nothing works out here, I'm just opting not to show anything.
        if ($editable) {
          $id=basename($i);
	  $editblock = "
            <a style=\"display: inline-block;\" onclick=\"switchMenu('$id');\">[Edit]</a>
            <div style=\"display: none;\" id=\"$id\">
             <form style=\"display: inline\" method=\"POST\">
              <input type=\"hidden\" name=\"id\" value=\"$i\" />
              <input type='hidden' name='action' value='Edit' />";
          if(is_null($json)) {
            $editblock .= "<textarea class=\"mbedit_text\" name=\"content\">$fc</textarea>";
          } else {
          $editblock .= '<input type="hidden" name="type" value="JSON" />
            Title: <input class="cooltext" type="text" name="title" value="'.$json->title.'" /><br />
            URL: <input class="cooltext" type="text" name="URL" value="'.$json->url.'" /><br />
            Image: <input class="cooltext" type="text" name="IMG" value="'.$json->image.'" /><br />
            Audio: <input class="cooltext" type="text" name="AUD" value="'.$json->audio.'" /><br />
            Video: <input class="cooltext" type="text" name="VID" value="'.$json->video.'" /><br />
            Comments: <textarea class="cooltext" name="comment">'.$json->comment.'</textarea>';
          }
          $editblock .= "<input class=\"coolbutton mbedit_button\" type=\"submit\" Value=\"Edit\" />
             </form>
             <form style=\"display: inline\" method=\"POST\">
              <input type=\"hidden\" name=\"id\" value=\"$i\" />
              <input type='hidden' name='action' value='Delete' />
              <input class=\"coolbutton mbedit_button\" type=\"submit\" value=\"Delete\" />
             </form>
            </div>
            <hr class=\"clear\" />";
          echo $editblock;
        }
      }
      echo "<a style=\"float: left;\" title=\"skips empty days\" href=\"?nav=2&date=".$yesterday."&fwd=0\">Older Entries</a>\n";
    }
    if ($tmrw) {
      echo "<a style=\"float: right;\" href=\"?nav=2&date=".$tomorrow."&fwd=1\">Newer Entries</a>\n";
    }
  }
?>
