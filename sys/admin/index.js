window.onload = navResize;
window.onresize = navResize;

function navResize() {
	if (window.innerWidth < 700) {
		//Hide original div, create new one if it doesn't exist
		document.getElementById('configbar').style.display = 'none';
		document.getElementById('menubutton').style.display = '';
	} else {
		//Show original div, axe new one
		document.getElementById('configbar').style.display = '';
		document.getElementById('menubutton').style.display = 'none';
		document.getElementById('littlemenu').style.display = 'none';
	}
}

function showMenu() {
	if (document.getElementById('littlemenu').style.display == 'none') {
		var pasta = document.getElementById('configbar').innerHTML;
		document.getElementById('littlemenu').innerHTML = pasta;
		document.getElementById('littlemenu').style.display = '';
	} else {
		document.getElementById('littlemenu').style.display = 'none';
	}
}
