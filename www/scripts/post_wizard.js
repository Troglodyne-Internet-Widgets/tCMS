// Post Type Wizard - repeatable custom field rows.
//
// Every row contributes exactly one param_name, param_type, param_label,
// param_placeholder, param_required, param_private and param_indexed, so they
// arrive server side as aligned arrays.  This is why 'required' is a <select>
// and not a checkbox -- an unchecked checkbox submits nothing and would shift
// every later row.
//
// 'Index this field' is a real checkbox because it reads like one, and keeps
// the guarantee anyway: the checkbox itself has no name and never submits, and
// the hidden input beside it -- which always submits, exactly once -- is what
// syncIndexedRow keeps in step with it.

function addParam() {
    var tpl  = document.getElementById('wizard-param-template');
    var host = document.getElementById('wizard-params');
    if ( tpl === null || host === null ) {
        console.log('post wizard param template missing');
        return false;
    }
    host.appendChild(document.importNode(tpl.content, true));

    // The row we just added is the last one; set its relation controls to
    // match whatever its type select says.
    var rows = host.querySelectorAll('.wizard-param-row');
    if (rows.length) {
        var added = rows[rows.length - 1].querySelector('.param-type');
        if (added) {
            syncRelationRow(added);
        }
    }
    return false;
}

// The relation selects are only meaningful for a relation field, but they must
// stay in the DOM and keep submitting whatever the type is -- the server zips
// the param_* arrays together positionally, so a row that submits fewer values
// than its neighbours shifts every row after it.  Hide, never remove.
function syncRelationRow(select) {
    var row = select.closest('.wizard-param-row');
    if (!row) {
        return false;
    }
    var relation = row.querySelector('.wizard-relation');
    if (relation) {
        relation.style.display = select.value === 'relation' ? '' : 'none';
    }
    return false;
}

// Copy a row's index checkbox into the hidden input that actually submits.
function syncIndexedRow(checkbox) {
    var row = checkbox.closest('.wizard-param-row');
    if (!row) {
        return false;
    }
    var hidden = row.querySelector('input[name="param_indexed"]');
    if (hidden) {
        hidden.value = checkbox.checked ? '1' : '0';
    }
    return false;
}

// Everything the wizard knows about the types which already exist, written into
// the page by post_wizard() as JSON rather than as JS, so that a display
// template full of markup cannot become code.
function wizardTypes() {
    var el = document.getElementById('wizard-types');
    if (el === null) {
        return {};
    }
    try {
        return JSON.parse(el.textContent) || {};
    } catch (e) {
        console.log('could not read the existing post types: ' + e);
        return {};
    }
}

function setField(name, value) {
    var el = document.querySelector('#postTypeWizard [name="' + name + '"]');
    if (!el) {
        return;
    }
    if (el.type === 'checkbox') {
        el.checked = value ? true : false;
        return;
    }
    if (el.type === 'textarea') {
        el.innerText = value;
        return;
    }
    el.value = value === null || value === undefined ? '' : value;
}

// Put the form into the state that produced the picked type, or back to blank
// for 'A new post type'.
function fillFromType(select) {
    var types = wizardTypes();
    var type  = types[select.value];
    var host  = document.getElementById('wizard-params');
    var about = document.getElementById('wizard-type-description');

    if (host) {
        host.innerHTML = '';
    }

    if (!type) {
        // Back to blank, but leave the canned-field checkboxes as the server
        // rendered them -- those are the defaults for a new type.
        setField('name', '');
        setField('display', '');
        setField('title_placeholder', '');
        setField('datasource', '');
        setField('description', '');
        setField('overwrite', false);
        if (about) {
            about.textContent = '';
        }
        addParam();
        return false;
    }

    setField('name', type.name);
    setField('display', type.display);
    setField('title_placeholder', type.title_placeholder);
    setField('datasource', type.datasource);
    setField('body_form', type.body_form);
    setField('description', type.description);

    var boxes = ['wrapper', 'inc_post_title', 'inc_post_tags', 'inc_preview',
                 'inc_tags', 'inc_aliases', 'inc_attachments'];
    for (var i = 0; i < boxes.length; i++) {
        setField(boxes[i], type[boxes[i]]);
    }

    // Saving it under the same name is the whole point of picking it, and
    // without this the save is refused with a message about ticking this box.
    setField('overwrite', true);

    if (about) {
        about.textContent = type.description ||
            (type.generated ? 'No description recorded for this type yet.'
                            : 'Written by hand rather than by the wizard, so there may be more to it than this form can show.');
    }

    var fields = type.fields || [];
    for (var f = 0; f < fields.length; f++) {
        addParam();
        fillParamRow(fields[f]);
    }
    if (!fields.length) {
        addParam();
    }

    return false;
}

// The row addParam() just appended is the last one.
function fillParamRow(field) {
    var rows = document.querySelectorAll('#wizard-params .wizard-param-row');
    if (!rows.length) {
        return;
    }
    var row = rows[rows.length - 1];

    var set = function (name, value) {
        var el = row.querySelector('[name="' + name + '"]');
        if (el) {
            el.value = value === null || value === undefined ? '' : value;
        }
    };

    set('param_name', field.name);
    set('param_type', field.type);
    set('param_label', field.label);
    set('param_placeholder', field.placeholder);
    set('param_required', field.required ? '1' : '0');
    set('param_private', field.private ? '1' : '0');
    set('param_indexed', field.indexed ? '1' : '0');
    set('param_relation_form', field.relation_form);
    set('param_relation_mode', field.relation_mode);

    // The checkbox has no name -- the hidden input beside it is what submits --
    // so it has to be brought into line by hand.
    var box = row.querySelector('.wizard-index input[type="checkbox"]');
    if (box) {
        box.checked = field.indexed ? true : false;
    }

    var type = row.querySelector('.param-type');
    if (type) {
        syncRelationRow(type);
    }
}

function delParam(button) {
    var row = button.closest('.wizard-param-row');
    if (row) {
        row.parentNode.removeChild(row);
    }
    return false;
}

// Start with one blank row, otherwise the feature isn't discoverable.
document.addEventListener("DOMContentLoaded", function(event) {
    if ( document.getElementById('wizard-params') !== null ) {
        addParam();
    }
});
