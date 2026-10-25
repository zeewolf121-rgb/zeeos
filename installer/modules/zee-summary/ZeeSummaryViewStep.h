/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * zee-summary (P4-6, #178, ADR-0003): replaces the stock summary page. Shows every planned disk
 * change per disk and keeps Install disabled until "I have a backup" is checked.
 * Writes nothing: it only reads the jobs the earlier pages queued.
 */
#ifndef ZEE_SUMMARY_VIEWSTEP_H
#define ZEE_SUMMARY_VIEWSTEP_H

#include "Config.h"

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/QmlViewStep.h"

class PLUGINDLLEXPORT ZeeSummaryViewStep : public Calamares::QmlViewStep
{
    Q_OBJECT

public:
    explicit ZeeSummaryViewStep( QObject* parent = nullptr );

    QString prettyName() const override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    Calamares::JobList jobs() const override;

    void onActivate() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

    QObject* getConfig() override { return m_config; }

private:
    QStringList plannedDiskJobs() const;

    Config* m_config;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( ZeeSummaryViewStepFactory )

#endif
