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
