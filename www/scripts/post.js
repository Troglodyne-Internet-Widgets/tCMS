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
    var thisPage = document.getElementById(id+'-'+page+'-page-option');
    if (thisPage) {
        thisPage.value = input.value;
        return false;
    }

    var newOption = document.createElement('option');
    newOption.value = input.value;
    newOption.innerText = "Page " + page;
    newOption.selected = true;
    newOption.id = id+'-'+page+"-page-option";
    select.appendChild(newOption);
}

function addPage(id) {
    var pageContainer = document.getElementById( 'content-pages-' + id );
    var lastPage = document.querySelector('#content-pages-'+id+' > textarea.data-page:nth-last-of-type(1)');
    var curPage;
    if (!lastPage) {
        curPage = 0;
    } else {
        var matches = /^[a-f0-9\-]*-(\d+)-page$/.exec(lastPage.id);
        // Go ahead and add this page in case we forgot.
        add2data(id, matches[1]);
        curPage = parseInt(matches[1]) + 1;
    }
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
    newTextArea.className = 'cooltext data-page';
    pageContainer.appendChild(newTextArea);
}

function addAllPages(id) {
    var pages = document.querySelectorAll('#content-pages-'+id+' textarea');
    for (page of pages) {
        var matches = /^[a-f0-9\-]*-(\d+)-page$/.exec(page.id);
        // Go ahead and add this page in case we forgot.
        add2data(id, matches[1]);
    }
    return true;
}
