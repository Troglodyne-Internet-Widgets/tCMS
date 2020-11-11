document.addEventListener("DOMContentLoaded", function(event) {
    var ads  = {
        "lrc": {
            "url":   "https://lewrockwell.com",
            "title": "Lew Rockwell",
            "img":   "lrc.png",
            "alt":   "LewRockwell.com: Embrace Liberty; Opt Out of the State"
        },
        "ernie": {
            "url":   "https://freedomsphoenix.com",
            "title": "Freedom's Phoenix",
            "img":   "ffenix.png",
            "alt":   "Freedom's Phoenix: Uncovering the Secrets, Exposing the Lies"
        },
        // The feens are done RIP
        //"feens": {
        //    "url":   "https://freedomfeens.com",
        //    "title": "Freedom Feens",
        //    "img":   "feen.png",
        //    "alt":   "Freedom Feens Radio Show: WORMS!"
        //},
        "ron": {
            "url":   "https://ronpaulinstitute.org",
            "title": "Ron Paul Institute for Peace and Prosperity",
            "img":   "rp2012.png",
            "alt":   "Ron Paul: End the Wars, End the Fed! Legalize Freedom."
        },
        // Sold out after getting scammed by Trump
        //"aj": {
        //    "url":   "https://prisonplanet.com",
        //    "title": "Alex Jones' InfoWars",
        //    "img":   "aj.png",
        //   "alt":   "Alex Jones' InfoWars: There's a War on for your Mind!"
        //},
        "mises": {
            "url":   "https://mises.org",
            "title": "The LvMI",
            "img":   "mises.png",
            "alt":   "The Ludwig von Mises Institute"
        },
        "spooner": {
            "url":   "https://en.wikisource.org/wiki/No_Treason/6",
            "title": "No Treason",
            "img":   "spooner.png",
            "alt":   "Lysander Spooner's 'No Treason: The Constitution of No Authority'"
        },
        "bastiat": {
            "url":   "https://en.wikisource.org/wiki/Essays_on_Political_Economy/The_Law",
            "title": "The Law",
            "img":   "bastiat.png",
            "alt":   "Frederick Bastiat's 'The Law'"
        },
        "larken": {
            "url":   "http://larkenrose.com/store/books/2019-the-most-dangerous-superstition.html",
            "title": "The Most Dangerous Superstition",
            "img":   "tdms.png",
            "alt":   "Larken Rose's 'The Most Dangerous Superstiton'"
        },
        "rats": {
            "url":   "http://rats-nosnitch.com",
            "title": "RATS",
            "img":   "rats.png",
            "alt":   "Claire Wolfe's 'RATS' (STOP SNITCHIN')"
        },
        "boston": {
            "url":   "http://javelinpress.com",
            "title": "Boston T. Party",
            "img":   "javelin.png",
            "alt":   "Javelin Press by Boston T. Party"
        }
    };
    var imgBase = window.themeDir+"/img/misc/";
    var keys    = Object.keys(ads);
    var maximum = (keys.length);
    var rand    = Math.floor(Math.random() * maximum);
    var ad      = ads[keys[rand]];
    var linkbar = document.getElementById("linodeAd");
    var newNode = document.createElement("a");
    newNode.setAttribute("href",  ad["url"]);
    newNode.setAttribute("title", ad["title"]);
    var img = document.createElement("img");
    img.setAttribute("src", imgBase + ad["img"]);
    img.setAttribute("alt", ad["alt"]);
    img.setAttribute("class", "jakes");
    newNode.appendChild(img);
    linkbar.parentNode.insertBefore(newNode, linkbar.nextSibling);
});
