/*

*/

Macro "Time of Day Split" (Args)

    RunMacro("Resident HB TOD", Args)
    return(1)
endmacro

/*
    Run choice model by purpose that predicts one of four periods AM, MD, PM, NT
    Fill tod field in person table
*/
Macro "Resident HB TOD" (Args)
    // Open person file and add TOD field
    person_file = Args.Persons
    pObj = CreateObject("Table", person_file)

    // Add temporary fields to person table
    flds = {{FieldName: "AM_Productions", Type: "real"},
            {FieldName: "MD_Productions", Type: "real"},
            {FieldName: "PM_Productions", Type: "real"},
            {FieldName: "NT_Productions", Type: "real"},
            {FieldName: "GroupBySegment", Type: "string", Width: 5}
            }
    pObj.AddFields({Fields: flds})

    // Open se_data
    se_file = Args.SE
    seObj = CreateObject("Table", se_file)
    trip_types = Args.HBTripTypes
    
    input_dir = Args.[Input Folder]
    input_tod_dir = input_dir + "/resident/tod"
    pbar = CreateObject("G30 Progress Bar", "Processing trip types for TOD", false, trip_types.length)
    for trip_type in trip_types do
        // Run TOD choice model to get probabilties
        util_file = input_tod_dir + "/" + trip_type + "_tod.csv"
        opts = {TripType: trip_type, PersonObject: pObj, UtilityFile: util_file}
        prob_file = RunMacro("Evaluate TOD Choice", opts)
        probObj = CreateObject("Table", prob_file)

        // Join probability file to person file and then aggregate by market segment, period and zone
        // Write data to se table
        // For each trip type, generate n + 4*n fields, where n is number of market segments and the 4 corresponds to the four time periods
        if trip_type = "W_HBW" then 
            segments = {"v0", "ilvi", "ilvs", "ihvi", "ihvs"}
        else 
            segments = {"v0", "vi", "vs"}
        spec = {TripType: trip_type, PersonObject: pObj, ProbObj: probObj, SEObj: seObj, Segments: segments}
        RunMacro("Aggregate HB Moto Trips", spec)

        probObj = null
        pbar.Step()
    end
    pbar.Destroy()

    // Drop temporary person fields
    pObj.DropFields({FieldNames: {"AM_Productions", "PM_Productions", "MD_Productions", "NT_Productions", "GroupBySegment"}})
    pObj = null
    seObj = null
endmacro


Macro "Evaluate TOD Choice"(spec)
    trip_type = spec.TripType
    pObj = spec.PersonObject
    util_file = spec.UtilityFile
    util = RunMacro("Import MC Spec", util_file)
    
    // Run choice model
    tag = trip_type + "_TOD"
    probFile = GetTempPath() + "\\" + tag + "_Probabilities.bin"
    obj = CreateObject("PMEChoiceModel", {ModelName: tag})
    obj.OutputModelFile = GetTempPath() + "\\" + tag + ".mdl"
    obj.AddTableSource({SourceName: "person", View: pObj.GetView(), IDField: "PersonID"})
    obj.AddUtility({UtilityFunction: util})
    obj.AddPrimarySpec({Name: "person"})
    obj.AddOutputSpec({ProbabilityTable: probFile})
    obj.ReportShares = 1
    ret = obj.Evaluate()
    if !ret then
        Throw("Running '" + tag + " choice model failed.")
    obj = null
    Return(probFile)
endMacro
