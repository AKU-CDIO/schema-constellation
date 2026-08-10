USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_Vaccines
    Purpose   : Builds a dedicated vaccine administration subset with dose, lot, route, CVX, and not-given reason.
    Grain     : one row per vaccine event and dose
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_Vaccines]
    @WindowStart DATE = '2022-11-05',
    @WindowEnd DATE = '2026-06-14',
    @MinimumPublishRows BIGINT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WindowStart IS NULL OR @WindowEnd IS NULL OR @WindowStart > @WindowEnd
        THROW 51000, 'A valid inclusive extraction window is required.', 1;
    IF @MinimumPublishRows < 1
        THROW 51000, 'MinimumPublishRows must be at least one.', 1;

    DECLARE @RunStart DATETIME2(0) = SYSDATETIME(), @RunEnd DATETIME2(0),
            @RecordCount BIGINT = 0, @TotalEligible BIGINT = 0;

    IF OBJECT_ID(N'dbo.FCAP1A_Cohort_Log', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID INT IDENTITY(1,1) PRIMARY KEY, RunStart DATETIME NOT NULL, RunEnd DATETIME NULL,
            DurationSeconds INT NULL, RunStatus VARCHAR(20) NOT NULL, DataTopic NVARCHAR(100) NOT NULL,
            WindowStart DATE NULL, WindowEnd DATE NULL, TotalEligible INT NULL, RecordCount INT NULL,
            ProcessedBy NVARCHAR(100) DEFAULT SYSTEM_USER, ErrorMessage NVARCHAR(4000) NULL,
            Remarks NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_Vaccines', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_Vaccines] (
            [VaccineEventKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VaccineEventID] INT NOT NULL,
            [VaccineID] NVARCHAR(80) NULL,
            [VaccineName] NVARCHAR(300) NULL,
            [EventDateTime] DATETIME2(0) NULL,
            [Given] BIT NULL,
            [ReasonGivenID] NVARCHAR(80) NULL,
            [ReasonNotGivenID] NVARCHAR(80) NULL,
            [Route] NVARCHAR(100) NULL,
            [AdministrationSiteID] NVARCHAR(80) NULL,
            [Dose] DECIMAL(18,4) NULL,
            [DoseUnits] NVARCHAR(60) NULL,
            [LotNumber] NVARCHAR(100) NULL,
            [LotExpirationDate] DATE NULL,
            [ManufacturerID] NVARCHAR(80) NULL,
            [NdcID] NVARCHAR(80) NULL,
            [CvxCode] NVARCHAR(80) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [EnteredByUserID] NVARCHAR(100) NULL,
            [Deleted] BIT NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Vaccines') AND name = N'UX_Vaccines_Key')
        CREATE UNIQUE INDEX [UX_Vaccines_Key] ON dbo.[tbl_FCAP1A_Vaccines] ([VaccineEventKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Vaccines') AND name = N'IX_Vaccines_PatientTime')
            CREATE INDEX [IX_Vaccines_PatientTime] ON dbo.[tbl_FCAP1A_Vaccines] ([PatientID], [EventDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [VaccineEventKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VaccineEventID] INT NOT NULL,
            [VaccineID] NVARCHAR(80) NULL,
            [VaccineName] NVARCHAR(300) NULL,
            [EventDateTime] DATETIME2(0) NULL,
            [Given] BIT NULL,
            [ReasonGivenID] NVARCHAR(80) NULL,
            [ReasonNotGivenID] NVARCHAR(80) NULL,
            [Route] NVARCHAR(100) NULL,
            [AdministrationSiteID] NVARCHAR(80) NULL,
            [Dose] DECIMAL(18,4) NULL,
            [DoseUnits] NVARCHAR(60) NULL,
            [LotNumber] NVARCHAR(100) NULL,
            [LotExpirationDate] DATE NULL,
            [ManufacturerID] NVARCHAR(80) NULL,
            [NdcID] NVARCHAR(80) NULL,
            [CvxCode] NVARCHAR(80) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [EnteredByUserID] NVARCHAR(100) NULL,
            [Deleted] BIT NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Ranked AS (
            SELECT v.*, vd.VaccineDose, vd.VaccineDoseUnits, vd.VaccineDoseInjectionSite_MisAdminSiteID,
                   vd.VaccineDoseLotNumber, vd.VaccineDoseLotExpirationDate, d.Name VaccineName, d.CvxCode_MisCvxCodeID,
                   ROW_NUMBER() OVER(PARTITION BY v.SourceID,v.PatientID,v.VaccineEventID
                                     ORDER BY vd.VaccineDoseUrnID,v.RowUpdateDateTime DESC) rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPat_Vaccines v
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=v.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPat_VaccinesDoses vd ON vd.SourceID=v.SourceID AND vd.PatientID=v.PatientID
                AND vd.Vaccine_MisVaccineID=v.Vaccine_MisVaccineID AND vd.VaccineEventID=v.VaccineEventID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisVaccine_Main d ON d.SourceID=v.SourceID AND d.MisVaccineID=v.Vaccine_MisVaccineID
            WHERE COALESCE(v.VaccineDate,v.VaccineEnteredDate) >= @WindowStart
              AND COALESCE(v.VaccineDate,v.VaccineEnteredDate) < DATEADD(DAY,1,@WindowEnd)
        )
        INSERT #Build ([VaccineEventKey], [SourceID], [PatientID], [VaccineEventID], [VaccineID], [VaccineName], [EventDateTime], [Given], [ReasonGivenID], [ReasonNotGivenID], [Route], [AdministrationSiteID], [Dose], [DoseUnits], [LotNumber], [LotExpirationDate], [ManufacturerID], [NdcID], [CvxCode], [FacilityID], [EnteredByUserID], [Deleted], [RowUpdateDateTime], [ExtractedOn])
        SELECT CONVERT(NVARCHAR(180),CONCAT(SourceID,'|',PatientID,'|',VaccineEventID)),SourceID,CONVERT(NVARCHAR(50),PatientID),
               VaccineEventID,CONVERT(NVARCHAR(80),Vaccine_MisVaccineID),CONVERT(NVARCHAR(300),VaccineName),
               CONVERT(DATETIME2(0),COALESCE(VaccineDate,VaccineEnteredDate)),
               CONVERT(BIT,CASE WHEN VaccineGiven IN ('Y','YES','1') THEN 1 WHEN VaccineGiven IN ('N','NO','0') THEN 0 END),
               CONVERT(NVARCHAR(80),VaccineReasonGiven_MisImmReasonID),CONVERT(NVARCHAR(80),VaccineReasonNotGiven_MisImmReasonID),
               CONVERT(NVARCHAR(100),VaccineRoute),CONVERT(NVARCHAR(80),VaccineDoseInjectionSite_MisAdminSiteID),
               TRY_CONVERT(DECIMAL(18,4),VaccineDose),CONVERT(NVARCHAR(60),VaccineDoseUnits),CONVERT(NVARCHAR(100),VaccineDoseLotNumber),
               TRY_CONVERT(DATE,VaccineDoseLotExpirationDate),CONVERT(NVARCHAR(80),VaccineManufacturer_MisMfrID),
               CONVERT(NVARCHAR(80),VaccineNdcNumber_MisNdcID),CONVERT(NVARCHAR(80),CvxCode_MisCvxCodeID),
               CONVERT(NVARCHAR(60),VaccineFacility_MisFacID),CONVERT(NVARCHAR(100),VaccineEnteredBy_UnvUserID),
               CONVERT(BIT,IIF(VaccineDeleted IN ('Y','YES','1'),1,0)),CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()
        FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_Vaccines];
            INSERT INTO dbo.[tbl_FCAP1A_Vaccines] ([VaccineEventKey], [SourceID], [PatientID], [VaccineEventID], [VaccineID], [VaccineName], [EventDateTime], [Given], [ReasonGivenID], [ReasonNotGivenID], [Route], [AdministrationSiteID], [Dose], [DoseUnits], [LotNumber], [LotExpirationDate], [ManufacturerID], [NdcID], [CvxCode], [FacilityID], [EnteredByUserID], [Deleted], [RowUpdateDateTime], [ExtractedOn])
            SELECT [VaccineEventKey], [SourceID], [PatientID], [VaccineEventID], [VaccineID], [VaccineName], [EventDateTime], [Given], [ReasonGivenID], [ReasonNotGivenID], [Route], [AdministrationSiteID], [Dose], [DoseUnits], [LotNumber], [LotExpirationDate], [ManufacturerID], [NdcID], [CvxCode], [FacilityID], [EnteredByUserID], [Deleted], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Vaccines',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             N'Author: test; staged and minimum-row-gated publication.');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, ErrorMessage, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Vaccines',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
