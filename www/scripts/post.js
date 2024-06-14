function switchMenu(obj) {
    var el = document.getElementById(obj);
    if ( el === null ) {
        console.log('no such element '+el);
        return;
    }
    if ( el.style.display != 'none' ) {
        el.style.display = 'none';
    } else {
        el.style.display = 'inline-block';
    }
}

function add2tags(id) {
    var select = document.getElementById( id + '-tags');
    var input  = document.getElementById( id + '-customtag');
    var newOption = document.createElement('option');
    newOption.value = input.value;
    newOption.innerText = input.value;
    newOption.selected = true;
    select.appendChild(newOption);
    input.value= '';
}

function add2aliases(id) {
    var select = document.getElementById( id + '-alias');
    var input  = document.getElementById( id + '-customalias');
    var newOption = document.createElement('option');
    newOption.value = input.value;
    newOption.innerText = input.value;
    newOption.selected = true;
    select.appendChild(newOption);
    input.value= '';
}

function add2data(id, page) {
    var select = document.getElementById( id + '-pages');
    var input  = document.getElementById( id + '-' + page + '-page');
    var newOption = document.createElement('option');
    newOption.value = input.value;
    newOption.innerText = "Page " + page;
    newOption.selected = true;
    select.appendChild(newOption);
}

function addPage(id) {
    var pageContainer = document.getElementById( 'content-pages-' + id );
    var curPage = 0; //TODO actually get this

    var newSpan = document.createTextNode('Page '+ curPage);
    pageContainer.appendChild(newSpan);
    var newButan = document.createElement('button');
    newButan.type = "button";
    newButan.className = "coolbutton emojiPicker";
    newButan.innerText = "😎";
    pageContainer.appendChild(newButan);
    var newBr = document.createElement('br');
    pageContainer.appendChild(newBr);
    var newTextArea = document.createElement('textarea');
    newTextArea.id = id + "-" + curPage + "-page";
    pageContainer.appendChild(newTextArea);
    var newSubmit = document.createElement('button');
    newSubmit.style="float:right;";
    newSubmit.setAttribute('onclick',"add2data('"+id+"', "+curPage+"); return false;");
    newSubmit.className = "coolbutton";
    newSubmit.innerText = "Add/Edit";
    pageContainer.appendChild(newSubmit);
}
