window.onload = navResize;
window.onresize = navResize;

function navResize() {
	if (window.innerWidth < 900) {
		//Hide original div, enable Menu Button 
		document.getElementById('righttitle').style.display = 'none';
		document.getElementById('menubutton').style.display = 'table-cell';
		document.getElementById('leftbar').style.display = 'none';
                document.getElementById('rightbar').style.display = 'none';
	} else {
		//Show original div, hide Menu Button 
		document.getElementById('righttitle').style.display = '';
		document.getElementById('leftbar').style.display = '';
                document.getElementById('rightbar').style.display = '';
		document.getElementById('menubutton').style.display = 'none';
		document.getElementById('littlemenu').style.display = 'none';
	}
}

function showMenu() {
	if (document.getElementById('littlemenu').style.display != 'none') {
		if (document.getElementById('littlemenu').style.display == 'block') {
			document.getElementById('littlemenu').style.display = '';
			document.getElementById('leftbar').style.display = 'none';
                	document.getElementById('rightbar').style.display = 'none';
			return;
		}
		var pasta = document.getElementById('righttitle').innerHTML;
		document.getElementById('littlemenu').innerHTML = pasta;
		document.getElementById('littlemenu').style.display = 'block';
		document.getElementById('leftbar').style.display = '';
                document.getElementById('rightbar').style.display = '';
	} 
}
