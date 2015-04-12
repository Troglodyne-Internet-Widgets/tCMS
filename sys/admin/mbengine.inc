<?php
  //TODO have include file here for string size validation function on titles, XSS Prevention (?)

  // Function for creating a post, used twice in the code below (thus it is encapsulated).
  function write_post($fh=null) {
    //Pull in config due to function scoping
    extract(json_decode(file_get_contents('config/main.json'),true));
    $errors = array();//Create empty error array
    //Validation checks
    $url = stripslashes($_POST["URL"]);
    if (empty($_POST['URL'])) {
      $errors[] = "No url provided.";
    } else if (!filter_var($url,FILTER_VALIDATE_URL)) {
      $errors[] = '"'.$url.'" is not a valid ASCII URL.';
    }
    if (!empty($_POST["IMG"]) && !filter_var(stripslashes($_POST["IMG"]),FILTER_VALIDATE_URL)) {
      $errors[] = 'Image "'.$url.'" is not a valid ASCII URL.';
    }
    if (!empty($_POST["AUD"]) && !filter_var(stripslashes($_POST["AUD"]),FILTER_VALIDATE_URL)) {
      $errors[] = 'Audio "'.$url.'" is not a valid ASCII URL.';
    }
    if (!empty($_POST["VID"]) && !filter_var(stripslashes($_POST["VID"]),FILTER_VALIDATE_URL)) {
      $errors[] = 'Video "'.$url.'" is not a valid ASCII URL.';
    }
    /*TODO Need to do extra validation here to prevent folks from doing something stupid
    (like inserting executable code or large hex dumps of files). FILTER_VALIDATE_URL should catch
    most of this, but especially on the title and commentary I can't be sure.*/
    if (!count($errors)) {//All POST Vars needed to construct a coherent posting are here, let's go 
      include_once("config/users.inc");//Import userland functions to figure out who's posting
      $postBody = array(
        "title"   => stripslashes($_POST["title"]),
        "url"     => $url,
        "image"   => stripslashes($_POST["IMG"]),
        "audio"   => stripslashes($_POST["AUD"]),
        "video"   => stripslashes($_POST["VID"]),
        "comment" => stripslashes($_POST["comment"]),
        "poster"  => $poster
      );//XXX Note here that if editing, it changes poster to whoever last edited the post
      if(empty($fh)) {//If none was passed in, we need to make one
        $tdtime = new DateTime(null, new DateTimeZone($timezone));
        $today = $tdtime->format('m.d.y');
        $now = $tdtime->format('H:i:s');
        $newsdir = $_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir;
        @mkdir($newsdir.$today);
        $fh = fopen($newsdir.$today."/".$now, 'w');
        if (!$fh) die("ERROR: couldn't write $newsdir$today/$now to $newsdir$today, check permissions");
      }
      fwrite($fh,json_encode($postBody));
      fclose($fh);
    } else {//Print errors at the top, since we didn't have what we needed from POST
      $message = 'Could not post due to errors:<br /><ul style="color: red; list-type: disc;">';
      foreach ($errors as $err) {$message .= "<li>$err</li>";}
      $message .= '</ul>POST Variable Dump below:<br /><em style="color: red; font-size: .75em;">'.print_r($_POST, true).'</em>';
      echo $message;
    }
  }

  //Microblog Posting engine - also used to display a form for submitting stories
  if($_SERVER['REQUEST_METHOD'] == 'POST') {//Don't do anything unless we are POSTing 
    if(empty($_POST["id"])) {//See if we need to post something new
      write_post(); 
    } else {//OK, so we've established that the post has an ID. Let's see if we're editing/deleting a post.
      if (!empty($_POST["action"]) && $_POST["action"] == 'Delete') {//BLANKING IN PROGRESS
        $res = unlink($_POST["id"]);
        if (!$res) {
          header("HTTP/1.1 500 Internal Server Error");
          die("ERROR: couldn't delete ".$_POST['id'].", check permissions");
        }
        echo "Deleted ".$_POST["id"]."<br />";
      } else {//Attempt editing, first detecting whether content is json
        $fh = fopen($_POST["id"], 'w');
        if (!$fh) {
          header("HTTP/1.1 500 Internal Server Error");
          die("ERROR (500): couldn't open ".$_POST['id'].", check permissions");
        }
        if(empty($_POST["type"]) && !empty($_POST["content"])) {//Do some munging if it's just raw text
          $content = stripslashes($_POST["content"]);
        } else {//Process the JSON Post, write to file
          write_post($fh);
        }
        fwrite($fh,$content);//Just write the blob ,TODO validation
        fclose($fh);
        echo "Edited ".$_POST["id"]."<br />";
      }
    }
  }
  //DOM below
?>
<div id="mbengine">
 <div id="submissions">
  <p class="title">Submissions:</p>
  <form id="Submissions" method="POST">
   Title *<br /><input class="cooltext" type="text" name="title" placeholder="Iowa Man Destroys Moon" />
   URL *<br /><input class="cooltext" type="text" name="URL" placeholder="https://oneweirdtrick.scam" />
   Image<br /><input class="cooltext" type="text" name="IMG" placeholder="https://gifdump.tld/Advice_Dog.jpg" />
   Audio<br /><input class="cooltext" type="text" name="AUD" placeholder="https://soundclod.com/static.mp3"/>
   Video<br /><input class="cooltext" type="text" name="VID" placeholder="https://youvimeo.tv/infomercial.mp4" />
   Comments:<br /><textarea class="cooltext" name="comment" placeholder="Potzrebie"></textarea>
   <input class="coolbutton" type="submit" value="Publish" text="Publish" />
  </form>
 </div>
 <div id="stories">
  <?php
   $editable = 1;
   include $_SERVER["DOCUMENT_ROOT"].'/'.$basedir."sys/microblog.inc";
  ?>
 </div>
</div>
