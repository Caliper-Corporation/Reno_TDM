/*
Called by flowchart
*/

Macro "Commercial Vehicles" (Args)
    RunMacro("CV Productions/Attractions", Args)
    RunMacro("CV TOD", Args)
    return(1)
endmacro

/*
Called by flowchart
*/

Macro "Commercial Vehicles DC" (Args)
    RunMacro("CV Gravity", Args)
    return(1)
endmacro

/*
CV productions
Attractions are the same as productions
*/

Macro "CV Productions/Attractions" (Args)

    se_file = Args.SE
    rate_file = Args.[CV Trip Rates]

    se = CreateObject("Table", {FileName: se_file})
    fields = {
        {FieldName: "IndManWar_Acres", Type: "Real", Description: "Industrial Manufacturing Warehousing in Acres"},
        {FieldName: "IndOther_Acres", Type: "Real", Description: "Industrial Other in Acres"}
        }
    se.AddFields({Fields: fields})
    IndManWar_Acres = if (se.NAICS11+se.NAICS21+se.NAICS22+se.NAICS23+se.NAICS31+se.NAICS32+se.NAICS33+se.NAICS42+se.NAICS48+se.NAICS49)=0 then 0 else 
	(se.NAICS31+se.NAICS32+se.NAICS33+se.NAICS48+se.NAICS49)/(se.NAICS11+se.NAICS21+se.NAICS22+se.NAICS23+se.NAICS31+se.NAICS32+se.NAICS33+se.NAICS42+se.NAICS48+se.NAICS49)*se.Industry_Acres
    se.SetDataVectors({FieldData: {{"IndManWar_Acres", IndManWar_Acres}}})
    IndOther_Acres = if (se.NAICS11+se.NAICS21+se.NAICS22+se.NAICS23+se.NAICS31+se.NAICS32+se.NAICS33+se.NAICS42+se.NAICS48+se.NAICS49)=0 then se.Industry_Acres else 
	(se.NAICS11+se.NAICS21+se.NAICS22+se.NAICS23+se.NAICS42)/(se.NAICS11+se.NAICS21+se.NAICS22+se.NAICS23+se.NAICS31+se.NAICS32+se.NAICS33+se.NAICS42+se.NAICS48+se.NAICS49)*se.Industry_Acres
    se.SetDataVectors({FieldData: {{"IndOther_Acres", IndOther_Acres}}})

    se_vw = OpenTable("se", "FFB", {se_file})
    {drive, folder, name, ext} = SplitPath(rate_file)
    RunMacro("Create Sum Product Fields", {
        view: se_vw, factor_file: rate_file,
        field_desc: "CV Productions and Attractions|See " + name + ext + " for details."
    })

    // Calibration
    calib_factor = .35
    se.CV = se.CV * calib_factor
    se.CVa = se.CVa * calib_factor
    se.SUT = se.SUT * calib_factor
    se.SUTa = se.SUTa * calib_factor
    se.MUT = se.MUT * calib_factor
    se.MUTa = se.MUTa * calib_factor
    CloseView(se_vw)
EndMacro

/*
Split CV productions and attractions into time periods
*/

Macro "CV TOD" (Args)

    se_file = Args.SE
    rate_file = Args.[CV TOD Rates]

    se_vw = OpenTable("se", "FFB", {se_file})
    {drive, folder, name, ext} = SplitPath(rate_file)
    RunMacro("Create Sum Product Fields", {
        view: se_vw, factor_file: rate_file,
        field_desc: "CV Productions and Attractions by Time of Day|See " + name + ext + " for details."
    })

    CloseView(se_vw)
endmacro

/*
Prepares arguments for the "Gravity" macro in the utils.rsc library.
*/

Macro "CV Gravity" (Args)

    out_dir = Args.[Output Folder]
    cv_dir = Args.[Input Folder] + "/cv"
    periods = RunMacro("Get Unconverged Periods", Args)

    for period in periods do

        RunMacro("Gravity", {
            se_file: Args.SE,
            skim_file: out_dir + "/skims/roadway/skim_sov_" + period + ".mtx",
            param_file: cv_dir + "/cv_gravity_" + period + ".csv",
            output_matrix: out_dir + "/cv/cv_gravity_" + period + ".mtx"
        })
    end
EndMacro