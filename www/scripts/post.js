function switchMenu(obj) {
    var el = document.getElementById(obj);
    if ( el.style.display != 'none' ) {
        el.style.display = 'none';
    } else {
        el.style.display = '';
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
