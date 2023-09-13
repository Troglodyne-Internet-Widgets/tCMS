function switchEmojiDropDown (e) {
    var panes = document.querySelectorAll('.mojipane');
    for (pane of panes) {
        pane.style.display="none";
    }

    var theId = e.target.value;
    var el = document.getElementById(theId);
    if ( el === null ) {
        console.log('no such element '+el);
        return;
    }
    el.style.display = 'inline-block';
}

window.onload = function () {
    var cat = document.getElementById('emoji-category');
    cat.addEventListener("change", switchEmojiDropDown);
    const ev = new Event("change");
    cat.dispatchEvent(ev);
}
