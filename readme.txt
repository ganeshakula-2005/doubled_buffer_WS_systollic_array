  >>>>>>>>>>>>>>>>>>>>>>>>>>  2D convolution  <<<<<<<<<<<<<<<<<<<<<<<<<<

      (image {col-1,2,3})                                           
               |
               v
        [ i00 i01 i02 ]              
        [ i10 i11 i12 ]         ->      [i00 i01 i02 i10 i11 i12 i20 i21 i22 ] (row 1,2,3 streched to col)
        [ i20 i21 i22 ]         ->      [i10 i11 i12 i20 i21 i22 i30 i31 i32 ] (row 2,3,4 streched to col)
        [ i30 i31 i32 ]         ->      [i20 i21 i22 i30 i31 i32 i40 i41 i42 ] (row 3,4,5 streched to col)
        [ i40 i41 i42 ]         ->      [i30 i31 i32 i40 i41 i42 i50 i51 i52 ] (row 4,5,6 streched to col)
        [ i50 i51 i52 ]         ->      [i40 i41 i42 i50 i51 i52 i60 i61 i62 ] (row 5,6,7 streched to col)
        [ i60 i61 i62 ]         ->      [i50 i51 i52 i60 i61 i62 i70 i71 i72 ] (row 6,7,8 streched to col)
        [ i70 i71 i72 ]         ->      [i60 i61 i62 i70 i71 i72 i80 i81 i82 ] (row 7,8,9 streched to col)
        [ i80 i81 i82 ]         ->      [i70 i71 i72 i80 i81 i82 i90 i91 i92 ] (row 8,9,10 streched to col)
        [ i90 i91 i92 ]                                                 .
               .                                                        .
               .                                                        .
               .

