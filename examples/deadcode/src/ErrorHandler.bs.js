// Generated by ReScript, PLEASE EDIT WITH CARE

import * as Curry from "rescript/lib/es6/curry.js";

function Make($$Error) {
  var notify = function (x) {
    return Curry._1($$Error.notification, x);
  };
  return {
          notify: notify
        };
}

var x = 42;

export {
  Make ,
  x ,
  
}
/* No side effect */
