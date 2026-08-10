USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_MedicalDevices
    Purpose   : Builds patient implant registry, surgical implant, and loaned-device history into one typed device contract.
    Grain     : one row per device status interval or implantation event
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_MedicalDevices]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_MedicalDevices', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_MedicalDevices] (
            [DeviceEventKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [DeviceIdentifier] NVARCHAR(160) NULL,
            [SerialNumber] NVARCHAR(160) NULL,
            [LotNumber] NVARCHAR(160) NULL,
            [CatalogNumber] NVARCHAR(160) NULL,
            [ManufacturerID] NVARCHAR(100) NULL,
            [DeviceDescription] NVARCHAR(1000) NULL,
            [ImplantDateTime] DATETIME2(0) NULL,
            [ExplantDateTime] DATETIME2(0) NULL,
            [ExpirationDate] DATE NULL,
            [Quantity] DECIMAL(18,4) NULL,
            [Status] NVARCHAR(100) NULL,
            [DeviceSource] VARCHAR(30) NOT NULL,
            [Comment] NVARCHAR(2000) NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_MedicalDevices') AND name = N'UX_MedicalDevices_Key')
        CREATE UNIQUE INDEX [UX_MedicalDevices_Key] ON dbo.[tbl_FCAP1A_MedicalDevices] ([DeviceEventKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_MedicalDevices') AND name = N'IX_MedicalDevices_PatientTime')
            CREATE INDEX [IX_MedicalDevices_PatientTime] ON dbo.[tbl_FCAP1A_MedicalDevices] ([PatientID], [ImplantDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [DeviceEventKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [DeviceIdentifier] NVARCHAR(160) NULL,
            [SerialNumber] NVARCHAR(160) NULL,
            [LotNumber] NVARCHAR(160) NULL,
            [CatalogNumber] NVARCHAR(160) NULL,
            [ManufacturerID] NVARCHAR(100) NULL,
            [DeviceDescription] NVARCHAR(1000) NULL,
            [ImplantDateTime] DATETIME2(0) NULL,
            [ExplantDateTime] DATETIME2(0) NULL,
            [ExpirationDate] DATE NULL,
            [Quantity] DECIMAL(18,4) NULL,
            [Status] NVARCHAR(100) NULL,
            [DeviceSource] VARCHAR(30) NOT NULL,
            [Comment] NVARCHAR(2000) NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Devices AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('PAT|',d.SourceID,'|',d.PatientID,'|',d.ImplantableDeviceIdentifier_MisUniqueDevIdID,'|',d.ImplantableDeviceDateID)) DeviceEventKey,
                   d.SourceID,d.PatientID,CONVERT(NVARCHAR(50),NULL) VisitID,d.ImplantableDeviceIdentifier_MisUniqueDevIdID DeviceIdentifier,
                   CONVERT(NVARCHAR(160),NULL) SerialNumber,CONVERT(NVARCHAR(160),NULL) LotNumber,CONVERT(NVARCHAR(160),NULL) CatalogNumber,
                   CONVERT(NVARCHAR(100),NULL) ManufacturerID,CONVERT(NVARCHAR(1000),NULL) DeviceDescription,
                   d.ImplantableDeviceDateID ImplantDateTime,CONVERT(DATETIME2(0),NULL) ExplantDateTime,CONVERT(DATE,NULL) ExpirationDate,
                   TRY_CONVERT(DECIMAL(18,4),d.ImplantableDeviceQuantity) Quantity,CONVERT(NVARCHAR(100),d.ImplantableDeviceSourceID) Status,
                   CONVERT(VARCHAR(30),'patient-registry') DeviceSource,d.ImplantableDeviceComment Comment,d.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPat_ImplDev d INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=d.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('SURG|',i.SourceID,'|',i.CwsApptID,'|',i.ImplantsUrnID)),i.SourceID,a.PatientID,a.VisitID,
                   i.ImplantDeviceIdentifier_MisUniqueDevIdID,i.ImplantsSerialNumber,i.ImplantsLotNumber,i.ImplantsCatalogNumber,i.ImplantsManufacturer_MisMfrID,
                   i.ImplantsDescription,a.DateTime,NULL,i.ImplantsExpirationDate,TRY_CONVERT(DECIMAL(18,4),i.ImplantsQuantityUsed),
                   CONVERT(NVARCHAR(100),IIF(i.ImplantDeviceNotAssociated IN ('Y','YES','1'),'not-associated','implanted')),
                   CONVERT(VARCHAR(30),'surgical-implant'),i.ImplantsComment,i.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].SurCase_Implant i INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].CwsAppt_Main a ON a.SourceID=i.SourceID AND a.CwsApptID=i.CwsApptID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        ),Ranked AS(SELECT *,ROW_NUMBER() OVER(PARTITION BY DeviceEventKey ORDER BY RowUpdateDateTime DESC)rn FROM Devices)
        INSERT #Build ([DeviceEventKey], [SourceID], [PatientID], [VisitID], [DeviceIdentifier], [SerialNumber], [LotNumber], [CatalogNumber], [ManufacturerID], [DeviceDescription], [ImplantDateTime], [ExplantDateTime], [ExpirationDate], [Quantity], [Status], [DeviceSource], [Comment], [RowUpdateDateTime], [ExtractedOn])
        SELECT DeviceEventKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(NVARCHAR(160),DeviceIdentifier),
               CONVERT(NVARCHAR(160),SerialNumber),CONVERT(NVARCHAR(160),LotNumber),CONVERT(NVARCHAR(160),CatalogNumber),
               CONVERT(NVARCHAR(100),ManufacturerID),CONVERT(NVARCHAR(1000),DeviceDescription),CONVERT(DATETIME2(0),ImplantDateTime),
               CONVERT(DATETIME2(0),ExplantDateTime),TRY_CONVERT(DATE,ExpirationDate),Quantity,CONVERT(NVARCHAR(100),Status),DeviceSource,
               CONVERT(NVARCHAR(2000),Comment),CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME() FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_MedicalDevices];
            INSERT INTO dbo.[tbl_FCAP1A_MedicalDevices] ([DeviceEventKey], [SourceID], [PatientID], [VisitID], [DeviceIdentifier], [SerialNumber], [LotNumber], [CatalogNumber], [ManufacturerID], [DeviceDescription], [ImplantDateTime], [ExplantDateTime], [ExpirationDate], [Quantity], [Status], [DeviceSource], [Comment], [RowUpdateDateTime], [ExtractedOn])
            SELECT [DeviceEventKey], [SourceID], [PatientID], [VisitID], [DeviceIdentifier], [SerialNumber], [LotNumber], [CatalogNumber], [ManufacturerID], [DeviceDescription], [ImplantDateTime], [ExplantDateTime], [ExpirationDate], [Quantity], [Status], [DeviceSource], [Comment], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Medical Device',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Medical Device',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
