USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Flowsheets_Extended]    Script Date: 7/13/2026 1:06:29 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* Stored Procedure: usp_Build_FCAP1A_Flowsheets_Extended
   
   Purpose:
     • Builds the FCAP 1A Flowsheets_Extended table for the Extended 10% cohort
     • Uses Meditech sources:
         - PhaPatData (anthropometrics / intake)
         - AdmVitalSigns (vitals / triage)
     • Restricts events to the fixed cohort window:
         2022-11-05 → 2026-01-31
     • Logs execution results to FCAP1A_Cohort_Log
   
   Author      : Allan Zablon
   Date        : 2026-02-19 (Extended fixed-window rebuild version)
   Revised		: 2026-07-13
    */

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Flowsheets_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    -- Move all DECLARE statements to the top of the BEGIN block to maintain scope
    DECLARE
        @RunStart DATETIME = SYSDATETIME(),
        @RunEnd DATETIME,
        @DurationSeconds INT,
        @RecordCount INT = 0,
        @TotalCohort INT = 0,
        @WindowStart DATE = '2022-11-05',
        @WindowEnd DATE   = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY, 1, '2026-06-14');

    
    -- 1. Ensure keyword-safe log table exists
    
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME NOT NULL,
            RunEnd          DATETIME NULL,
            DurationSeconds INT NULL,
            RunStatus       VARCHAR(20) NOT NULL,      -- SUCCESS / FAILED
            DataTopic       NVARCHAR(100) NOT NULL,    -- e.g., 'Flowsheets_Extended'
            WindowStart     DATE NULL,
            WindowEnd       DATE NULL,
            TotalEligible   INT NULL,
            RecordCount     INT NULL,
            ProcessedBy     NVARCHAR(100) DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000) NULL,
            Remarks         NVARCHAR(4000) NULL
        );
    END;

    
    -- 2. Drop & recreate target table
    
    IF OBJECT_ID('dbo.tbl_FCAP1A_Flowsheets_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Flowsheets_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Flowsheets_Extended (
        PatientID NVARCHAR(50) NOT NULL,
        VisitID NVARCHAR(50) NOT NULL,
        SourceID NVARCHAR(10) NULL,
        Sex NVARCHAR(20) NULL,
        Bed NVARCHAR(50) NULL,
        RoomID NVARCHAR(50) NULL,
        LocationID NVARCHAR(50) NULL,
        Status NVARCHAR(50) NULL,
        HeightInCentimeters DECIMAL(18,4) NULL,
        HeightInFeet INT NULL,
        HeightInInches DECIMAL(18,4) NULL,
        WeightInKilograms DECIMAL(18,4) NULL,
        WeightInPounds DECIMAL(18,4) NULL,
        BodySurfaceArea DECIMAL(18,4) NULL,
        DischargeHeightInCentimeters DECIMAL(18,4) NULL,
        DischargeWeightInKg DECIMAL(18,4) NULL,
        BloodPressure NVARCHAR(50) NULL,
        Pulse NVARCHAR(50) NULL,
        Respiration NVARCHAR(50) NULL,
        Temperature NVARCHAR(50) NULL,
        ChiefComplaint NVARCHAR(500) NULL,
        TriageLevelID NVARCHAR(20) NULL,
        TriageLevelName NVARCHAR(100) NULL,
        LastEventDateTime DATETIME NULL,
        DischargeDateTime DATETIME NULL,
        ErTriageDateTime DATETIME NULL,
        RowUpdateDateTime DATETIME NULL,
        ExtractedFrom NVARCHAR(200) NULL,
        ExtractedOn DATETIME DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tbl_FCAP1A_Flowsheets_Extended PRIMARY KEY (PatientID, VisitID)
    );

    BEGIN TRY
        
        -- 3. Insert data for full fixed window
        
        INSERT INTO dbo.tbl_FCAP1A_Flowsheets_Extended (
            PatientID, VisitID, SourceID, Sex, Bed, RoomID, LocationID, Status,
            HeightInCentimeters, HeightInFeet, HeightInInches,
            WeightInKilograms, WeightInPounds, BodySurfaceArea,
            DischargeHeightInCentimeters, DischargeWeightInKg,
            BloodPressure, Pulse, Respiration, Temperature,
            ChiefComplaint, TriageLevelID, TriageLevelName,
            LastEventDateTime, DischargeDateTime, ErTriageDateTime,
            RowUpdateDateTime, ExtractedFrom
        )
        SELECT DISTINCT
            c.PatientID,
            v.VisitID,
            COALESCE(p.SourceID, vs.SourceID) AS SourceID,
            p.Sex,
            p.Bed,
            p.RoomID,
            p.LocationID,
            p.Status,
            TRY_CAST(p.HeightInCentimeters AS DECIMAL(18,4)) AS HeightInCentimeters,
            p.HeightInFeet,
            TRY_CAST(p.HeightInInches AS DECIMAL(18,4)) AS HeightInInches,
            TRY_CAST(p.WeightInKilograms AS DECIMAL(18,4)) AS WeightInKilograms,
            TRY_CAST(p.WeightInPounds AS DECIMAL(18,4)) AS WeightInPounds,
            TRY_CAST(p.BodySurfaceArea AS DECIMAL(18,4)) AS BodySurfaceArea,
            TRY_CAST(p.DischargeHeightInCentimeters AS DECIMAL(18,4)) AS DischargeHeightInCentimeters,
            TRY_CAST(p.DischargeWeightInKg AS DECIMAL(18,4)) AS DischargeWeightInKg,
            vs.BloodPressure,
            vs.Pulse,
            vs.Respiration,
            vs.Temperature,
            vs.ChiefComplaint,
            vs.TriageLevelID,
            vs.TriageLevelName,
            p.LastEventDateTime,
            p.DischargeDateTime,
            vs.ErTriageDateTime,
            COALESCE(p.RowUpdateDateTime, vs.RowUpdateDateTime) AS RowUpdateDateTime,
            'PhaPatData + AdmVitalSigns (AKULivendb)' AS ExtractedFrom
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            ON c.PatientID COLLATE DATABASE_DEFAULT = v.PatientID COLLATE DATABASE_DEFAULT
        LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.PhaPatData AS p
            ON v.VisitID = p.VisitID
        LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVitalSigns AS vs
            ON v.VisitID = vs.VisitID
        WHERE COALESCE(p.LastEventDateTime, vs.ErTriageDateTime,
                       p.RowUpdateDateTime, vs.RowUpdateDateTime) >= @WindowStart 
          AND COALESCE(p.LastEventDateTime, vs.ErTriageDateTime,
                       p.RowUpdateDateTime, vs.RowUpdateDateTime) < @WindowEndNextDay;

        
        -- 4. Log metrics
        
        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Flowsheets_Extended;
        SELECT @TotalCohort = COUNT(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus,
             DataTopic, WindowStart, WindowEnd,
             RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
             'Flowsheets_Extended', @WindowStart, @WindowEnd,
             @RecordCount, SYSTEM_USER,
             'Flowsheets_Extended rebuild successful (' +
             CAST(@RecordCount AS VARCHAR(10)) +
             ' rows, fixed window 2022-11-05 → 2026-01-31).');

        PRINT 'Flowsheets_Extended table built successfully.';
        PRINT 'Rows inserted: ' + CAST(@RecordCount AS VARCHAR(10));
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(10));

    END TRY
    BEGIN CATCH
        
        -- 5. Log error details
        
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        INSERT INTO dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, RunStatus, DataTopic,
             WindowStart, WindowEnd, ProcessedBy,
             ErrorMessage, Remarks)
        VALUES
            (@RunStart, SYSDATETIME(), 'FAILED', 'Flowsheets_Extended',
             @WindowStart, @WindowEnd, SYSTEM_USER,
             @Err, 'Error during Flowsheets_Extended fixed-window rebuild.');

        THROW;
    END CATCH;
END;
