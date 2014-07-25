<?php
 $dir = $_GET['dir'];
 $pwd = $dir;

 //These variables are to check whether the directory we will link to exists, and to know what directory we are in 
 $check = @scandir($pwd.'/../', 1);
 $splode = preg_split('[/]', $pwd, -1);
 $predir = count($splode)-1;
 $test = array_slice($splode, -1, 1);

 #Establish MIME Type data
 #Link is used to specify special handler URLS for particular files
 #File specifies the link icon
 $arch_types = array(".tar",".gz",".z7",".bz",".bz2",".zip",".rar",".lsz",
		    "link" => "",
		    "file" => "tsarchive.gif");
 //Only MP3 supported for now
 $audio_types = array(".mp3",
		     "link" => "index.php?nav=7&post=",
		     "file" => "tsaudio.gif");
 $video_types = array(".ogv",
		     "link" => "index.php?nav=8&post=",
		     "file" => "tsmovie.gif");
 $image_types = array(".bmp",".gif",".jpg",".jpeg",".png",".ico",".svg",".xpm",
		     "link" => "index.php?nav=9&post=",
		     "file" => "tsimage.gif");
 $schematic_types = array(".dwg",".dxf",".cad",".gcode",".mcode",
			 "link" => "",
			 "file" => "tsschematic.gif");
 $model_types = array(".stl",".blend",".3ds",
		     "link" => "",
		     "file" => "tsmodel.gif");
 $binary_types = array(".exe",".o",".dll",".so",".jnilib",".a",".bin",".hex",
		      "link" => "",
		      "file" => "tssoftware.gif");
 $code_types = array(".py",".c",".h",".js",".php",".tcl",".m",".txt",
		    "link" => "index.php?nav=6&post=",
		    "file" => "tscode.gif");
 $doc_types = array(".htm",".html",".post",
		   "link" => "index.php?nav=5&post=",
                   "file" => "tsdoc.png");
 $legacy_types = array(".pdf",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".pages",".ai",".psd",".tiff",".tif",".eps",".ps",".xps",
		   "link" => "index.php?nav=10&post=",
		   "file" => "tsprop.png");
 $mime_types = array($arch_types,$audio_types,$video_types,$image_types,$schematic_types,$model_types,$binary_types,$code_types,$doc_types,$legacy_types);

 //Find the directory contents
 $ls = @scandir($pwd, 1);

// $dlist = array_filter($ls,function ($a) {return is_dir($a);});
 $dban1 = '.';
 $dban2 = '..';
 $dkey = array_search($dban1,$ls);
 if ($dkey!==false){unset($ls[$dkey]);};
 $dkey = array_search($dban2,$ls);
 if ($dkey!==false){unset($ls[$dkey]);};

 //See if this directory is even there
 if (@in_array($test[0], $check)) {
	echo 'Directory listing for '.$pwd;
	echo '<hr />';
	$cnt = count($ls);
    $dlist = array();
    $flist = array();

    //Trying to sort here
    for ($n = 0; $n < $cnt; $n++) {
        $filechk = @scandir($pwd.'/'.$ls[$n]);
        if (! $filechk) {
            foreach($mime_types as $mimes) {
                foreach($mimes as $type) {
                    $sstrn = @stristr($ls[$n],$type);
                    if($sstrn !== FALSE && strlen($sstrn) == strlen($type)) {
                        array_push($flist, $ls[$n]);
                    }
                }
            }
        }
        else {
            array_push($dlist, $ls[$n]);
        }
    }
    sort($dlist);
    sort($flist);
    $ls = array_merge($dlist,$flist);
	
    //Yeah, I know this looks familiar. There's prolly some way to combine this by setting the $ikon and $link vars as an array.
    for ($n = 0; $n < $cnt; $n++) {

		//create links based on whether we are a file, and if otherwise we are a directory
		$filechk = @scandir($pwd.'/'.$ls[$n]);
		if (! $filechk) {
			//default values for uncaught filetypes
			$ikon = "tsfile.gif";
			$link = "";

			foreach ($mime_types as $mimes) {
				foreach ($mimes as $type) {
					//$link = $mimes["link"];
                                        $sstrn = @stristr($ls[$n],$type);
					if ($sstrn !== FALSE && strlen($sstrn) == strlen($type)) {
						$ikon = $mimes["file"];
						$link = $mimes["link"];
						break 2;
					};
				};
			};
			echo '<img class="icon" src='.$icondir.$ikon.' />';
			echo '<a href="'.$link.$pwd.'/'.$ls[$n].'">'.$ls[$n].'</a><br />';
		}
		else {
			echo '<img src="'.$icondir.'tsfolder.gif" />';
			echo '<a href="index.php?nav=1&dir='.$pwd.'/'.$ls[$n].'">'.$ls[$n].'</a><br />'."\n";
		}
	}

	//Figure out what the previous directory is
	$prevdirname = '';

	for ($i =0; $i < $predir; $i++) {

		//We want to catch the first case, and not put a / before it
		if ($i == 0) {
			$prevdirname = $prevdirname.$splode[$i];
		}
		else {
			$prevdirname = $prevdirname.'/'.$splode[$i];
		}
	}

	//If we are not in the TLD, make a link to the previous dir
	if ($prevdirname <> '') {

		echo '<img src="'.$icondir.'tsfolder-up.gif" />';
		echo '<a href="index.php?nav=1&dir='.$prevdirname.'">Up one level</a>'."\n";

	}
 }

 //Catch bogus directories
 else {
 	include 'sys/fileshare/include/notfound';
 }
?> 
