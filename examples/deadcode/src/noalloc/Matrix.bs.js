// Generated by ReScript, PLEASE EDIT WITH CARE


function sumVec(v) {
  var match = v[1];
  var match$1 = v[0];
  return [
          match$1[0] + match[0] | 0,
          match$1[1] + match[1] | 0
        ];
}

function rotation(a) {
  return [
          [
            0.0,
            -1.0 * a,
            0.0
          ],
          [
            a,
            0.0,
            0.0
          ],
          [
            0.0,
            0.0,
            a
          ]
        ];
}

function mulVecVec(v1, v2) {
  var x = v1[0] * v2[0];
  var y = v1[1] * v2[1];
  var z = v1[2] * v2[2];
  return x + y + z;
}

function mulMatVec(m, v) {
  var x = mulVecVec(m[0], v);
  var y = mulVecVec(m[1], v);
  var z = mulVecVec(m[2], v);
  return [
          x,
          y,
          z
        ];
}

function scale(s) {
  return [
          [
            s,
            1.0,
            1.0
          ],
          [
            1.0,
            s,
            1.0
          ],
          [
            1.0,
            1.0,
            s
          ]
        ];
}

function restMatrix(v) {
  return mulMatVec(rotation(0.123), mulMatVec(scale(2.0), v));
}

var scale2 = [
  [
    2.0,
    1.0,
    1.0
  ],
  [
    1.0,
    2.0,
    1.0
  ],
  [
    1.0,
    1.0,
    2.0
  ]
];

function restMatrix2(v) {
  return mulMatVec(rotation(0.123), mulMatVec(scale2, v));
}

export {
  sumVec ,
  rotation ,
  mulVecVec ,
  mulMatVec ,
  scale ,
  restMatrix ,
  scale2 ,
  restMatrix2 ,
}
/* No side effect */
