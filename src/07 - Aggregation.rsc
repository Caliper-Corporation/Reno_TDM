/*
    Given a trip type and the tod probabilities for each person:
    - Split the motorized (i.e) <type>_m field by TOD
    - Aggregate these fields by TAZ (by segment)
    - e.g. Given the motorized purpose field W_HBO_m,
        produce W_HBO_v0, W_HBO_vi, W_HBO_vs and W_HB0_v0_AM, W_HB0_v0_MD, W_HB0_v0_PM, W_HB0_v0_NT etc
        Produce n + 4n = 5n fields where n is number of market segments
*/
Macro "Aggregate HB Moto Trips" (spec)
    trip_type = spec.TripType
    pObj = spec.PersonObject
    probObj = spec.ProbObj
    segments = spec.Segments
    seObj = spec.seObj

    // Create empty se fields tp fill
    flds = null
    for seg in segments do
        flds = flds + {{FieldName: trip_type + "_" + seg, Type: "real"},
                        {FieldName: trip_type + "_" + seg + "_AM", Type: "real"},
                        {FieldName: trip_type + "_" + seg + "_MD", Type: "real"},
                        {FieldName: trip_type + "_" + seg + "_PM", Type: "real"},
                        {FieldName: trip_type + "_" + seg + "_NT", Type: "real"}
                       }
    end
    seObj.AddFields({Fields: flds})

    // Join TOD probabibilty file to persons table and fill temporary fields
    objJ = pObj.Join({Table: probObj, LeftFields: "PersonID", RightFields: "ID"})

    // Create temp fields (product of main production field and TOD percent)
    pFld = trip_type + "_m"
    vecsSet = null
    // Fill segment info
    if Lower(trip_type) = "w_hbw" then
        vecsSet.GroupBySegment = objJ.market_segment
    else do
        v = objJ.market_segment
        vOut = if v = "v0" then "v0"
                else if v = "ilvi" or v = "ihvi" then "vi"
                 else "vs"
        vecsSet.GroupBySegment = vOut
    end
    vecsSet.AM_Productions = nz(objJ.(pFld)) * nz(objJ.[AM Probability])
    vecsSet.MD_Productions = nz(objJ.(pFld)) * nz(objJ.[MD Probability])
    vecsSet.PM_Productions = nz(objJ.(pFld)) * nz(objJ.[PM Probability])
    vecsSet.NT_Productions = nz(objJ.(pFld)) * nz(objJ.[NT Probability])
    objJ.SetDataVectors({FieldData: vecsSet})
    objJ = null
    
    // Aggregate by zone, segment and fill tod fields in se table
    fldStats = {"AM_Productions": "sum", "MD_Productions": "sum", "PM_Productions": "sum", "NT_Productions": "sum"}
    aggObj = pObj.Aggregate({GroupBy: {"HHTAZ", "GroupBySegment"}, FieldStats: fldStats})

    for seg in segments do
        qry = printf("GroupBySegment = '%s'", {seg})
        n = aggObj.SelectByQuery({Query: qry, SetName: "__" + seg})
        aggObj.ChangeSet("__" + seg)
        if n > 0 then do
            expObj = aggObj.Export({FileName: GetTempPath() + "ExportedTripsByTOD.bin"})
            
            // Fill se data
            objJ = seObj.Join({Table: expObj, LeftFields: "TAZ", RightFields: "HHTAZ"})
            vecsSet = null
            vecsSet.(trip_type + "_" + seg + "_AM") = nz(objJ.sum_AM_Productions)
            vecsSet.(trip_type + "_" + seg + "_MD") = nz(objJ.sum_MD_Productions)
            vecsSet.(trip_type + "_" + seg + "_PM") = nz(objJ.sum_PM_Productions)
            vecsSet.(trip_type + "_" + seg + "_NT") = nz(objJ.sum_NT_Productions)
            vecsSet.(trip_type + "_" + seg) = vecsSet.(trip_type + "_" + seg + "_AM") + 
                                                vecsSet.(trip_type + "_" + seg + "_MD")+ 
                                                    vecsSet.(trip_type + "_" + seg + "_PM") + 
                                                        vecsSet.(trip_type + "_" + seg + "_NT")
            objJ.SetDataVectors({FieldData: vecsSet})
            objJ = null
            
            expObj = null
        end
    end
    aggObj = null
endMacro
