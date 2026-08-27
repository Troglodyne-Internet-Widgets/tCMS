// Post Type Wizard - repeatable custom field rows.
//
// Every row contributes exactly one param_name, param_type, param_label,
// param_placeholder and param_required, so the five arrive server side as
// aligned arrays.  This is why 'required' is a <select> and not a checkbox --
// an unchecked checkbox submits nothing and would shift every later row.

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
