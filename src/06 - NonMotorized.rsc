/*

*/
Macro "NonMotorized Choice" (Args)
    RunMacro("Create NonMotorized Features", Args)
    RunMacro("Calculate NM Probabilities", Args)
    RunMacro("Separate NM Trips", Args)
    RunMacro("Aggregate HB NonMotorized Trips", Args)
    return(1)
endmacro

Macro "NM Distribution" (Args)
    RunMacro("NM Gravity", Args)
    return(1)
endmacro

Macro "NM Time-of-Day" (Args)
    RunMacro("NM TOD", Args)
    RunMacro("NM Integerization", Args)
    return(1)
endmacro

Macro "NM Assignment" (Args)
    RunMacro("Assign Bike Trips", Args)
    return(1)
endmacro

/*
This macro creates features on the synthetic household and person tables
needed by the non-motorized model.
*/

Macro "Create NonMotorized Features" (Args)

    hh_file = Args.Households
    per_file = Args.Persons

    hh_vw = OpenTable("hh", "FFB", {hh_file})
    per_vw = OpenTable("per", "FFB", {per_file})
    hh_fields = {
        {"veh_per_adult", "Real", 10, 2,,,, "Vehicles per Adult"},
        {"inc_per_capita", "Real", 10, 2,,,, "Income per person in household"}
    }
    RunMacro("Add Fields", {view: hh_vw, a_fields: hh_fields})
    per_fields = {
        {"age_16_18", "Integer", 10, ,,,, "If person's age is 16-18"},
        {"veh_per_adult", "Real", 10, 2,,,, "Vehicles per Adult in household"},
        {"inc_per_capita", "Real", 10, 2,,,, "Income per person in household"},
        {"HHKids", "Real", 10, 2,,,, "Num kids in household"},
        {"HHSize", "Real", 10, 2,,,, "Num persons in household"},
        {"HHAdults", "Real", 10, 2,,,, "Num adults in household"}
    }
    RunMacro("Add Fields", {view: per_vw, a_fields: per_fields})

    {v_size, v_kids, v_autos, v_inc} = GetDataVectors(
        hh_vw + "|", {"HHSize", "HHKids", "Autos", "HHInc"},
    )

    v_adult = v_size - v_kids
    v_vpa = v_autos / v_adult
    SetDataVector(hh_vw + "|", "veh_per_adult", v_vpa, )
    v_ipc = v_inc / v_size
    SetDataVector(hh_vw + "|", "inc_per_capita", v_ipc, )
    v_age = GetDataVector(per_vw + "|", "Age", )
    v_age_flag = if v_age >= 16 and v_age <= 18 then 1 else 0
    SetDataVector(per_vw + "|", "age_16_18", v_age_flag, )
    CloseView(per_vw)
    CloseView(hh_vw)

    // add HH fields to person table
    per = CreateObject("Table", per_file)
    per_specs = per.GetFieldSpecs({NamedArray: true})
    hh = CreateObject("Table", hh_file)
    hh_specs = hh.GetFieldSpecs({NamedArray: true})
    joined = per.Join({
        Table: hh,
        LeftFields: {"HouseholdID"},
        RightFields: {"HouseholdID"}
    })
    joined.(per_specs.veh_per_adult) = joined.(hh_specs.veh_per_adult)
    joined.(per_specs.inc_per_capita) = joined.(hh_specs.inc_per_capita)
    joined.(per_specs.HHKids) = joined.(hh_specs.HHKids)
    joined.(per_specs.HHSize) = joined.(hh_specs.HHSize)
    joined.(per_specs.HHAdults) = joined.(hh_specs.HHAdults)
endmacro

/*
Loops over each trip type and applies the binary choice model to split
trips into a "motorized" or "nonmotorized" mode.

Inputs
    * trip_types
        * Optional Array
        * Specific trip types to run this macro for
        * If null, will run for all HB trip types
        * Used by calibration macros
*/

Macro "Calculate NM Probabilities" (Args, trip_types)

    scen_dir = Args.[Scenario Folder]
    input_dir = Args.[Input Folder]
    input_nm_dir = Args.NMInputFolder
    output_dir = Args.[Output Folder] + "/resident/nonmotorized"
    households = Args.Households
    persons = Args.Persons

    if trip_types = null then trip_types = Args.HBTripTypes
    primary_spec = {Name: "person", OField: "ZoneID"}
    for trip_type in trip_types do

        obj = null
        obj = CreateObject("PMEChoiceModel", {ModelName: trip_type})
        obj.OutputModelFile = output_dir + "\\" + trip_type + ".mdl"
        obj.AddTableSource({
            SourceName: "se",
            File: scen_dir + "\\output\\sedata\\scenario_se.bin",
            IDField: "TAZ"
        })
        obj.AddTableSource({
            SourceName: "person",
            IDField: "PersonID",
            File: persons
        })
        util = RunMacro("Import MC Spec", input_nm_dir + "/" + trip_type + ".csv")
        obj.AddUtility({UtilityFunction: util})
        obj.AddPrimarySpec(primary_spec)
        nm_table = output_dir + "\\" + trip_type + ".bin"
        obj.AddOutputSpec({ProbabilityTable: nm_table})
        obj.RandomSeed = 199999
        obj.Evaluate()
    end
endmacro

/*
This creates new, motorized-only fields on the person table

Inputs
    * trip_types
        * Optional Array
        * Specific trip types to run this macro for
        * If null, will run for all HB trip types
        * Used by calibration macros
*/

Macro "Separate NM Trips" (Args, trip_types)
    
    output_dir = Args.[Output Folder] + "/resident/nonmotorized"
    per_file = Args.Persons
    
    per = CreateObject("Table", per_file)

    if trip_types = null then trip_types = Args.HBTripTypes

    for trip_type in trip_types do
        // Add field to person table
        per_out_field = trip_type + "_m"
        bike_field = trip_type + "_bike"
        walk_field = trip_type + "_walk"
        per.AddFields({Fields: {
            {FieldName: per_out_field, Description: "Motorized " + trip_type + " person trips"},
            {FieldName: bike_field, Description: "Bike " + trip_type + " person trips"},
            {FieldName: walk_field, Description: "Walk " + trip_type + " person trips"}
        }})
        
        nm_file = output_dir + "/" + trip_type + ".bin"
        nm = CreateObject("Table", nm_file)
        
        // Add field to nm table
        nm.AddFields({Fields: {
            {FieldName: bike_field, Description: "Bike person trips"},
            {FieldName: walk_field, Description: "Walk person trips"}
        }})

        // Join tables and calculate results
        per_specs = per.GetFieldSpecs({NamedArray: true})
        nm_specs = nm.GetFieldSpecs({NamedArray: true})
        join = per.Join({
            Table: nm,
            LeftFields: {"PersonID"},
            RightFields: {"ID"}
        })
        v_pct_bike = join.(nm_specs.("bike Probability"))
        v_pct_walk = join.(nm_specs.("walk Probability"))
        v_total = join.(per_specs.(trip_type))
        
        v_bike = v_total * v_pct_bike
        v_walk = v_total * v_pct_walk
        v_moto = v_total * (1 - v_pct_bike - v_pct_walk)
        
        join.(per_specs.(per_out_field)) = v_moto
        join.(per_specs.(bike_field)) = v_bike
        join.(per_specs.(walk_field)) = v_walk
        join.(nm_specs.(bike_field)) = v_bike
        join.(nm_specs.(walk_field)) = v_walk

        join = null
        nm = null
    end
endmacro


/*
Aggregates the non-motorized trips to TAZ

Inputs
    * trip_types
        * Optional Array
        * Specific trip types to run this macro for
        * If null, will run for all HB trip types
        * Used by calibration macros
*/

Macro "Aggregate HB NonMotorized Trips" (Args, trip_types)

    hh_file = Args.Households
    per_file = Args.Persons
    mz_file = Args.[Input MZ]
    nm_dir = Args.[Output Folder] + "/resident/nonmotorized"

    per_df = CreateObject("df", per_file)
    per_df.select({"PersonID", "HouseholdID"})
    hh_df = CreateObject("df", hh_file)
    hh_df.select({"HouseholdID", "ZoneID", "MZ"})
    per_df.left_join(hh_df, "HouseholdID", "HouseholdID")

    if trip_types = null then trip_types = Args.HBTripTypes
    for trip_type in trip_types do
        file = nm_dir + "/" + trip_type + ".bin"
        vw = OpenTable("temp", "FFB", {file})
        v_bike = GetDataVector(vw + "|", trip_type + "_bike", {{"Sort Order",{{"ID","Ascending"}}}})
        v_walk = GetDataVector(vw + "|", trip_type + "_walk", {{"Sort Order",{{"ID","Ascending"}}}})
        CloseView(vw)
        per_df.tbl.(trip_type + "_bike") = v_bike
        per_df.tbl.(trip_type + "_walk") = v_walk
    end
    per_df.group_by("MZ")
    to_summarize = V2A(A2V(trip_types) + "_bike") + V2A(A2V(trip_types) + "_walk")
    per_df.summarize(to_summarize, "sum")
    for trip_type in to_summarize do
        per_df.rename("sum_" + trip_type, trip_type)
    end
    
    // Add the NM attractions from the MZ bin file, which will
    // be used in the gravity application.
    mz_df = CreateObject("df", mz_file)
    mz_df.tbl.NMAttractions = mz_df.tbl.HH + mz_df.tbl.TOTJOBS
    mz_df.select({"ID", "NMAttractions"})
    mz_df.left_join(per_df, "ID", "MZ")
    mz_df.write_bin(nm_dir + "/_agg_nm_trips_daily.bin")
    mz_df = null

    // // Suppress demand for walk trips in zones with no walk accessibility
    // agg_vw = OpenTable("aggnm", "FFB", {nm_dir + "/_agg_nm_trips_daily.bin"})
    // SetView(agg_vw)
    // n = SelectByQuery("Selection", "several", "Select * where access_walk = 0",)
    // v0 = GetDataVector(agg_vw + "|Selection", "access_walk", )
    // for trip_type in trip_types do
    //     SetDataVector(agg_vw + "|Selection", trip_type + "_walk", v0, )
    // end

endmacro

/*

*/

Macro "NM Gravity" (Args)

    walk_params = Args.[Input Folder] + "/resident/nonmotorized/distribution/walk_gravity.csv"
    bike_params = Args.[Input Folder] + "/resident/nonmotorized/distribution/bike_gravity.csv"
    out_dir = Args.[Output Folder] 
    nm_dir = out_dir + "/resident/nonmotorized"
    prod_file = nm_dir + "/_agg_nm_trips_daily.bin"

    RunMacro("Gravity", {
        se_file: prod_file,
        skim_file: out_dir + "/skims/nonmotorized/walk_skim_mz.mtx",
        row_index: "MZ",
        col_index: "MZ",
        param_file: walk_params,
        output_matrix: nm_dir + "/walk_gravity.mtx"
    })
    RunMacro("Gravity", {
        se_file: prod_file,
        skim_file: out_dir + "/skims/nonmotorized/bike_skim_mz.mtx",
        row_index: "MZ",
        col_index: "MZ",
        param_file: bike_params,
        output_matrix: nm_dir + "/bike_gravity.mtx"
    })
endmacro

/*
Split the non-motorized trips up by time of day using the same factors as
the motorized trips.
*/

Macro "NM TOD" (Args)

    nm_dir = Args.[Output Folder] + "/resident/nonmotorized"
    tod_file = Args.ResTODFactors
    links_dbd = Args.Links
    maz_file = Args.[Input MZ]
    
    fac_vw = OpenTable("tod_fac", "CSV", {tod_file})
    v_type = GetDataVector(fac_vw + "|", "trip_type", )
    v_tod = GetDataVector(fac_vw + "|", "tod", )
    v_fac = GetDataVector(fac_vw + "|", "factor", )

    modes = {"walk", "bike"}
    for mode in modes do
        nm_file = nm_dir + "/" + mode + "_gravity.mtx"
        nm_mtx = CreateObject("Matrix", nm_file)
        for i = 1 to v_type.length do
            type = v_type[i]
            tod = v_tod[i]
            fac = v_fac[i]

            core_name = type + "_" + tod
            nm_mtx.AddCores({core_name})
            cores = nm_mtx.GetCores()
            cores.(core_name) := cores.(type) * fac
        end
        nm_mtx = null
    end

    // Create the combined matrix used by the NHB model
    // Combine the MAZ matrices
    CopyFile(nm_dir + "/walk_gravity.mtx", nm_dir + "/nm_gravity_mz.mtx")
    nm_mtx = CreateObject("Matrix", nm_dir + "/nm_gravity_mz.mtx")
    bike_mtx = CreateObject("Matrix", nm_dir + "/bike_gravity.mtx")
    core_names = nm_mtx.GetCoreNames()
    for core_name in core_names do
        nm_mtx.(core_name) := nz(nm_mtx.(core_name)) + nz(bike_mtx.(core_name))
    end
    // Aggregate to TAZ level
    agg_mtx = nm_mtx.Aggregate({
        Method: "Sum",
        Rows: {
            Data: maz_file,
            MatrixID: "ID",
            AggregationID: "TAZ_ID"
        },
        Cols: {
            Data: maz_file,
            MatrixID: "ID",
            AggregationID: "TAZ_ID"
        }
    })
    core_names = agg_mtx.GetCoreNames()
    for core_name in core_names do
        new_names = new_names + {Substitute(core_name, "Sum of ", "", )}
    end
    agg_mtx.RenameCores({CurrentNames: core_names, NewNames: new_names})
    // Create new matrix with correct dimensions (including external tazs)
    node_tbl = CreateObject("Table", {FileName: links_dbd, LayerType: "Node"})
    node_tbl.SelectByQuery({
        SetName: "tazs",
        Query: "Select * where TAZ <> null"
    })
    specs = node_tbl.GetFieldSpecs({NamedArray: true})
    vw = node_tbl.GetView()
    mh = CreateMatrix(
        {vw + "|tazs", specs.ID, "TAZ"},
        {vw + "|tazs", specs.ID, "TAZ"},
        {
            "File Name": nm_dir + "/nm_gravity.mtx", 
            Label: "Combined Bike-Walk Matrix",
            Tables: new_names
        }
    )
    // Create sub index
    mz_tbl = CreateObject("Table", maz_file)
    agg_tbl = mz_tbl.Aggregate({
        GroupBy: "TAZ_ID",
        FieldStats: {TAZ_ID: "Count"}
    })
    final_mtx = CreateObject("Matrix", mh)
    final_mtx.AddIndex({
        ViewName: agg_tbl.GetView(),
        Dimension: "Both",
        OriginalID: "TAZ_ID",
        NewID: "TAZ_ID",
        IndexName: "with_trips"
    })
    final_mtx.SetIndex({
        RowIndex: "with_trips",
        ColIndex: "with_trips"
    })
    for core_name in new_names do
        final_mtx.(core_name) := agg_mtx.(core_name)
    end    
endmacro

/*
Integerizes the bike matrix by iteratively lowering the rounding threshold
until the rounded sums are close to the true sums.
*/

Macro "NM Integerization" (Args)

    out_dir = Args.[Output Folder] + "/resident/nonmotorized"
    nm_file = out_dir + "/bike_gravity.mtx"
    int_file = out_dir + "/bike_int.mtx"    
    tod_file = Args.ResTODFactors
    v_tod = Args.Periods
    
    fac_tbl = CreateObject("Table", tod_file)
    v_type = fac_tbl.trip_type
    v_type = SortVector(v_type, {Unique: true})
    
    CopyFile(nm_file, int_file)
    mtx = CreateObject("Matrix", int_file)
    mtx.AddCores("floor")
    mtx.AddCores("rem")
    mtx.AddCores("temp_sum")
    
    for type in v_type do
        for tod in v_tod do
            core_name = type + "_" + tod
            row_sums = mtx.GetVector({
                Core: core_name,
                Marginal: "Row Sum"
            })
            true_sum = row_sums.Sum()

            mtx.floor := Floor(mtx.(core_name))
            mtx.rem := mtx.(core_name) - mtx.floor
            round_threshold = .02
            for i = 1 to 100 do
                mtx.temp_sum := if mtx.rem >= round_threshold then mtx.floor + 1 else mtx.floor
                row_sums = mtx.GetVector({
                    Core: "temp_sum",
                    Marginal: "Row Sum"
                })
                temp_sum = row_sums.Sum()
                ratio = (temp_sum - true_sum) / true_sum
                thresholds = thresholds + {round_threshold} // for debugging speed of convergence
                ratios = ratios + {ratio} // for debugging speed of convergence
                if abs(ratio) < .015 or i = 100 then do
                    mtx.(core_name) := mtx.temp_sum
                    break
                end else if ratio < -.015
                    then round_threshold = round_threshold / 1.10
                    else round_threshold = round_threshold * 1.07
            end
        end
    end
    mtx.DropCores({"floor", "rem", "temp_sum"})

    // Create a single "bike" core for assignment
    mtx.AddCores("bike")
    mtx.bike := 0
    for type in v_type do
        for tod in v_tod do
            core_name = type + "_" + tod
            mtx.bike := mtx.bike + nz(mtx.(core_name))
        end
    end
EndMacro

/*
Assigns the non-motorized trips to the network
*/
Macro "Assign Bike Trips" (Args)
    
    hwy_dbd = Args.Links
    net_dir = Args.[Output Folder] + "\\networks\\"
    net_file = net_dir + "net_bike.net"
    assn_dir = Args.[Output Folder] + "\\assignment\\nonmotorized"
    if GetDirectoryInfo(assn_dir, "All") = null then CreateDirectory(assn_dir)
    od_dir = Args.[Output Folder] + "/resident/nonmotorized"
    od_mtx = od_dir + "/bike_int.mtx"

    // Add NodeID index to matrix
    node_tbl = CreateObject("Table", {FileName: hwy_dbd, LayerType: "Node"})
    mtx = CreateObject("Matrix", od_mtx)
    mtx.AddIndex({
        ViewName: node_tbl.GetView(),
        Dimension: "Both",
        OriginalID: "MAZID",
        NewID: "ID",
        IndexName: "NodeID"
    })
    node_tbl = null
    mtx = null

    o = CreateObject("Network.Assignment")
    o.Network = net_file
    o.LayerDB = hwy_dbd
    o.ResetClasses()
    o.Method = "AON"
    o.DemandMatrix({MatrixFile: od_mtx, RowIndex: "NodeID", ColIndex: "NodeID"})
    o.AddClass({Demand: "bike"})
    o.Minimize = "BikeTime"
    o.FlowTable = assn_dir + "\\bike_flow.bin"
    ret_value = o.Run()
    results = o.GetResults()
endmacro
