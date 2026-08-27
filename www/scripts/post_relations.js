// Fills in the dropdowns for relation fields -- the ones a post type declares
// when it depends on posts of another type.
//
// The options are fetched rather than baked into the generated template so the
// picker can't go stale: posts of the target type come and go long after the
// type itself was written.  Auth rides the tcmslogin cookie, so a same origin
// request needs nothing else.

function populateRelationPicker(select) {
    var form = select.getAttribute('data-relation-form');
    if (!form) {
        return;
    }

    var req = new XMLHttpRequest();
    req.addEventListener("load", function () {
        var payload;
        try {
            payload = JSON.parse(this.responseText);
        } catch (e) {
            console.log('could not read the post list for ' + form + ': ' + e);
            return;
        }

        var selected = select.getAttribute('data-selected') || '';

        // A relation that isn't required needs a way to say "none".
        if (!select.required) {
            select.appendChild(new Option('(none)', ''));
        }

        for (var post of payload.posts || []) {
            var option = new Option(post.title, post.id);
            option.selected = post.id === selected;
            select.appendChild(option);
        }
    });
    req.addEventListener("error", function () {
        console.log('could not fetch the post list for ' + form);
    });
    req.open("GET", "/api/posts_of_form?form=" + encodeURIComponent(form));
    req.send();
}

document.addEventListener("DOMContentLoaded", function(event) {
    var pickers = document.querySelectorAll('select.relation-picker');
    for (var picker of pickers) {
        populateRelationPicker(picker);
    }
});
