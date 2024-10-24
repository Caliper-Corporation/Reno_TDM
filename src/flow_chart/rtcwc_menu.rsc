
Class "Visualize.Menu.Items"

    init do 
        self.runtimeObj = CreateObject("Model.Runtime")
    enditem 

    Macro "GetMenus" do
        Menus = {
             { ID: "ConvChart", Title: "Convergence Chart" , Macro: "Menu_ConvergenceChart" }
            ,{ ID: "FlowMap", Title: "Flow Map" , Macro: "Menu_FlowMapt" }
            ,{ ID: "M_Chord", Title: "Chord Diagram" , Macro: "Menu_Chord" }
            ,{ ID: "M_Sankey", Title: "Sankey Diagram" , Macro: "Menu_Sankey" }
            }
        
        Return(Menus)
    enditem 

    Macro "Menu_FlowMapt" do 
        opts.tableArg = self.runtimeObj.GetSelectedParamInfo().Value
        opts.FlowFields = {"AB_Flow","BA_Flow"}
        opts.vocFields = {"AB_VOC","BA_VOC"}
        opts.LineLayer = self.runtimeObj.GetValue("HWYDB")
        self.runtimeObj.RunCode("CreateFlowThemes", opts)
        enditem 

    Macro "Menu_ConvergenceChart" do 
        tableArg = self.runtimeObj.GetSelectedParamInfo().Value
        self.runtimeObj.RunCode("ConvergenceChart", {TableName: tableArg})
        enditem 

    macro "Menu_Chord" do 
        mName = self.runtimeObj.GetSelectedParamInfo().Value
        TAZGeoFile = self.runtimeObj.GetValue("TG_ZonalTable")
        self.runtimeObj.RunCode("CreateWebDiagram", {MatrixName: mName, TAZDB: TAZGeoFile, DiagramType: "Chord"})
    enditem         

    macro "Menu_Sankey" do 
        mName = self.runtimeObj.GetSelectedParamInfo().Value
        TAZGeoFile = self.runtimeObj.GetValue("TG_ZonalTable")
        self.runtimeObj.RunCode("CreateWebDiagram", {MatrixName: mName, TAZDB: TAZGeoFile, DiagramType: "Sankey"})
    enditem         

EndClass


MenuItem "RTCWC Menu Item" text: "RTCWC"
    menu "RTCWC Menu"

menu "RTCWC Menu"
    init do
    enditem

    MenuItem "Create Scenario" text: "Create Scenario"
        do 
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        {, scen_name} = mr.GetScenario()

        // Check that a scenario is selected and that a folder has been chosen
        if scen_name = null then do
            ShowMessage("Choose a scenario.")
            return()
        end
        if Args.[Scenario Folder] = null then do
            ShowMessage(
                "Choose a folder for the current scenario\n" +
                "(Parameters -> Files -> Scenario -> Input)"
            )
            return()
        end

        mr.RunCode("Create Scenario", Args)
        return(1)
    enditem

    separator

    MenuItem "Utils" text: "Tools"
        menu "RTCWC Utilities"
    
    MenuItem "Calibrators" text: "Calibrators"
        menu "RTCWC Calibrators"

    separator

    MenuItem "AQ Reports" text: "Run AQ Reports" do
       btn = MessageBox("This report will generate estimated VMT, VHT and average speeds by speed category, facility type, and urban/rural type. You need to perform a full model run before running this report. Do you want to continue?",
            {Caption: "Question", Buttons: "YesNo"})
        if btn = "Yes" then do

            mr = CreateObject("Model.Runtime")
            Args = mr.GetValues()
            ret_value = mr.RunCode("AQ Summaries", Args)
            if ret_value then
                ShowMessage("AQ Reports ran successfully.")
            else
                ShowMessage("AQ Reports failed.")
        end
    enditem


endMenu 
menu "RTCWC Utilities"
    init do
    enditem

    MenuItem "Highway" text: "Highway Analysis"
        menu "Highway Analysis"

    MenuItem "Matrix" text: "Delete Files"
        menu "Delete Files"

    MenuItem "Comparison" text: "Scenario Comparison"
        menu "Scenario Comparison"
    
    MenuItem "Input" text: "Input Data Processing"
        menu "Input Data Processing"

    MenuItem "Performance" text: "Performance Measures"
        menu "Performance Measures"
    
endMenu

menu "Highway Analysis"
    init do
    enditem
    
    MenuItem "desire_lines" text: "Desire Lines" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Open Desire Lines Dbox", Args)
    enditem

    MenuItem "fixed_od" text: "Fixed OD Assignment" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Open Fixed OD Dbox", Args)
    enditem
endMenu

menu "Delete Files"
    init do
    enditem

    MenuItem "Delete Files Tool" text: "Delete Matrix Files" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Open Delete Files Tool Dbox", Args)
    enditem

endMenu

menu "Scenario Comparison"
    init do
    enditem
  
    MenuItem "scen comp" text: "Scenario Comparison" do
        mr = CreateObject("Model.Runtime")
        mr.RunCodeEx("Open Scenario Comp Tool")
    enditem
endMenu

menu "Input Data Processing"
    init do
    enditem

    MenuItem "diff" text: "Diff Tool" do
        mr = CreateObject("Model.Runtime")
        mr.RunCodeEx("Open Diff Tool")
    enditem

    MenuItem "merge_tool" text: "Merge Line Layers" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCodeEx("Open Merge Dbox", Args)
    enditem
endMenu

menu "Performance Measures"
    init do
    enditem

    MenuItem "MOVES" text: "MOVES Input Preparation" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Open Prepare MOVES Input Dbox", Args)
    enditem

endMenu

menu "RTCWC Calibrators"
    init do
    enditem

    MenuItem "AO" text: "Auto Ownership" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Calibrate AO", Args)
    enditem

    MenuItem "NM" text: "Nonmotorized" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Calibrate NM", Args)
    enditem

    MenuItem "HB Mode Choice" text: "Home Based Trips Mode Choice" do
        mr = CreateObject("Model.Runtime")
        Args = mr.GetValues()
        mr.RunCode("Calibrate HB MC", Args)
    enditem
endMenu



