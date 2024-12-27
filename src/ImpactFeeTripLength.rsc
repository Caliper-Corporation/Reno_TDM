/*

	This tool calculates a weighted-average trip length for districts to support the VMT-based impact
	fee program in RTC.  The length calculated only includes the portion of each trip on regional roads.

	It requires that the network's node layer have the districts for calculation designated in a field called "FeeDist".


*/

Macro "ImpactFeeTripLength" (Args)

    scen_folder = Args.[Scenario Folder] + "\\"
    model_dir = Args.[Model Folder] + "\\"

	// Input variables
	hwy_file = scen_folder + "output\\networks\\scenario_links.dbd"
	node_table = scen_folder + "output\\networks\\scenario_links_.dbd"
	monster_file = model_dir + "\\master\\networks\\master_links.dbd"

    a_period = {"am","md","pm","nt"}

	// Output variables
	on error goto skipfolder
	    outputfolder = scen_folder + "output\\_summaries\\AverageRegTripLength"
		CreateDirectory(outputfolder)
	skipfolder:
	on error default
    outputfolder = outputfolder + "\\"
	net_file = outputfolder + "network.net"
    csv_file = outputfolder + "result.csv"

    report = OpenFile(csv_file, "w")

    link_tbl = CreateObject("Table", {FileName: hwy_file, LayerType: "Line"})
    link_tbl.AddField({FieldName: "RegLength", Description: "Regional Length. 0 for non-regional roads"})
    link_tbl.RegLength = 0

	// Fill in the RegLength field
    link_tbl.SelectByQuery({
        SetName: "regroads",
        Filter: "Regional_Road <> 0"
    })

    link_tbl.RegLength = link_tbl.Length

    // Determine the number of districts
    node_tbl = CreateObject("Table", {FileName: hwy_file, LayerType: "Node"})
    v_feedist = node_tbl.FeeDist
    v_uniqdist = SortVector(v_feedist,{{"Unique","True"}})
    num_dist = v_uniqdist.length - 1    // Subtract 1 because non-TAZ nodes have a null value

    link_tbl = null
    node_tbl = null


	// Create a network
    map = CreateObject("Map", hwy_file)
    {node_lyr, link_lyr} = map.GetLayerNames()
	SetLayer(link_lyr)

     Opts = null
     Opts.Input.[Link Set] = {hwy_file + "|" + link_lyr, link_lyr}
     Opts.Global.[Network Options].[Node ID] = node_lyr + ".ID"
     Opts.Global.[Network Options].[Link ID] = link_lyr + ".ID"
     Opts.Global.[Network Options].[Turn Penalties] = "Yes"
     Opts.Global.[Network Options].[Keep Duplicate Links] = "FALSE"
     Opts.Global.[Network Options].[Ignore Link Direction] = "FALSE"
     Opts.Global.[Network Options].[Time Unit] = "Minutes"
     Opts.Global.[Link Options].Length = {link_lyr + ".Length", link_lyr + ".Length", , , "False"}

    Opts.Global.[Link Options].time_am = {link_lyr + ".ABAMTime", link_lyr + ".BAAMTime", , , "False"}
    Opts.Global.[Link Options].time_md = {link_lyr + ".ABMDTime", link_lyr + ".BAMDTime", , , "False"}
    Opts.Global.[Link Options].time_pm = {link_lyr + ".ABPMTime", link_lyr + ".BAPMTime", , , "False"}
    Opts.Global.[Link Options].time_nt = {link_lyr + ".ABNTTime", link_lyr + ".BANTTime", , , "False"}

     Opts.Global.[Link Options].RegLength = {link_lyr + ".RegLength", link_lyr + ".RegLength", , , "False"}
     Opts.Global.[Node Options].TAZ = {node_lyr + ".TAZ", , }
     Opts.Global.[Node Options].Centroid = {node_lyr + ".Centroid", , }
     Opts.Global.[Node Options].FeeDist = {node_lyr + ".FeeDist", , }
     Opts.Global.[Length Unit] = "Miles"
     Opts.Global.[Time Unit] = "Minutes"
     Opts.Output.[Network File] = net_file

    RunMacro("TCB Init")
     ret_value = RunMacro("TCB Run Operation", "Build Highway Network", Opts, &Ret)


    // Create an array to hold the resulting average values in order to calculate a daily average
    // Trips and Weighted Distance by time period and district (periods x districts x 2)
    dim a_results[a_period.length,num_dist,2]

    WriteLine(report, "TOD,Avg Trip Length to North, Avg Trip Length to South")

	// Loop over TOD

    for t = 1 to a_period.length do

        skimmtx_file = outputfolder + a_period[t] + "skim.mtx"
        aggRLxTRPmtx_file = outputfolder + a_period[t] + "_aggRLxTRP.mtx"
        avgTRPLmtx_file = outputfolder + a_period[t] + "_avgTripLength.mtx"
        odmtx_file = scen_folder + "output\\assignment\\roadway\\od_veh_trips_" + a_period[t] + ".mtx"

         Opts = null
         Opts.Input.Network = net_file
         Opts.Input.[Origin Set] = {hwy_file + "|" + node_lyr, node_lyr, "centroids", "Select * where Centroid=1"}
         Opts.Input.[Destination Set] = {hwy_file + "|" + node_lyr, node_lyr, "centroids"}
         Opts.Input.[Via Set] = {hwy_file + "|" + node_lyr, node_lyr}
         Opts.Field.Minimize = "time_" + a_period[t]
         Opts.Field.Nodes = node_lyr + ".ID"
         Opts.Field.[Skim Fields].Length = "All"
         Opts.Field.[Skim Fields].RegLength = "All"
         Opts.Output.[Output Matrix].Label = "Shortest Path"
         Opts.Output.[Output Matrix].[File Name] = skimmtx_file

         ret_value = RunMacro("TCB Run Procedure", "TCSPMAT", Opts, &Ret)



        // ----------------------
        //
        //		Matrix Setup
        //
        // ----------------------

        // Cores of interest (non-transit only)
        a_corenames = {
                        "sov",
                        "hov2",
                        "hov3",
                        "CV",
                        "SUT",
                        "MUT"}


        // Open Matrices
        mtx_od = CreateObject("Matrix", odmtx_file)
        mtx_skim = CreateObject("Matrix", skimmtx_file)

        // Add the new core to the OD matrix if it doesn't already exist
        a_existcorenames = mtx_od.GetCoreNames()
        if ArrayPosition(a_existcorenames, {"nontransit"},) = 0 then mtx_od.AddCores("nontransit")

        mtx_od.nontransit := 0

        for core in a_corenames do
            mtx_od.nontransit := mtx_od.nontransit + mtx_od.(core)
        end

        // Create a core/currency for the multiplication table
        a_existcorenames = mtx_skim.GetCoreNames()
        if ArrayPosition(a_existcorenames, {"RLxTRIPS"},) = 0 then mtx_skim.AddCores("RLxTRIPS")
        
        mtx_skim.RLxTRIPS := mtx_skim.("RegLength (Skim)") * mtx_od.nontransit

        // Aggregate matrix based on the fee district designation on the node layer
        Opts = null
        Opts.[File Name] = aggRLxTRPmtx_file
        Opts.Label = "Regional Length * " + a_period[t] + " Trips"
        mtx_aggRLxTRP = AggregateMatrix(mtx_skim.RLxTRIPS, {node_lyr+".TAZ",node_lyr+".FeeDist"}, {node_lyr+".TAZ",node_lyr+".FeeDist"}, Opts)
        mtx_aggRLxTRP = CreateObject("Matrix", mtx_aggRLxTRP)

        Opts = null
        Opts.[File Name] = avgTRPLmtx_file
        Opts.Label = a_period[t] + " Trips"
        mtx_aggavg = AggregateMatrix(mtx_od.nontransit, {node_lyr+".TAZ",node_lyr+".FeeDist"}, {node_lyr+".TAZ",node_lyr+".FeeDist"}, Opts)
        mtx_aggavg = CreateObject("Matrix", mtx_aggavg)

        // Add the new core to the aggregated matrix if it doesn't already exist
        a_existcorenames = mtx_aggavg.GetCoreNames()
        if ArrayPosition(a_existcorenames, {"averageTripLength"},) = 0 then mtx_aggavg.AddCores("averageTripLength")


        // Create matrix currencies for the aggregated tables and calculate the average
        mtx_aggavg.averageTripLength := mtx_aggRLxTRP.RLxTRIPS / mtx_aggavg.nontransit

        // Get the total number of districts
        a_column_labels = mtx_aggRLxTRP.GetVector({Core: "RLxTRIPS", Index: "Row"})

        // Get matrix marginals
        a_tripto = mtx_aggavg.GetVector({Core: "nontransit", Marginal: "Row Sum"})
        a_wghtdistto = mtx_aggRLxTRP.GetVector({Core: "RLxTRIPS", Marginal: "Row Sum"})

        // Calculate the final averages
        string = a_period[t]
        
        for i = 1 to num_dist do
            string = string + "," + string(round( a_wghtdistto[i] / a_tripto[i],2 ))
            a_results[t][i][1] = a_wghtdistto[i]
            a_results[t][i][2] = a_tripto[i]
        end

        // Write result to file
        WriteLine(report, string)

        // Delete the aggRLxTRP.mtx
        mtx_aggavg = null
        mtx_aggRLxTRP = null
        DeleteFile(aggRLxTRPmtx_file)
        DeleteFile(avgTRPLmtx_file)
    end

    DeleteFile(net_file)

    // After each period is calculated, calculate the daily average
    string = "Daily"
    for i = 1 to num_dist do
        dailywghtdist = 0
        dailytrips = 0
        for t = 1 to a_period.length do
            dailywghtdist = dailywghtdist + a_results[t][i][1]
            dailytrips = dailytrips +  a_results[t][i][2]
        end
            dailyavgdist = round(dailywghtdist / dailytrips,2)
            string = string + "," + string(dailyavgdist)
    end

    // Write out the daily avg
	WriteLine(report, string)

    CloseFile(report)
EndMacro
