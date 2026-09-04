//
//  OBJParallelBlockPlugin.h
//  objekat
//
//  Bloc de plugins PARALLÈLES : au lieu d'une chaîne, N chaînes qui partent de la même
//  entrée et se resomment en sortie. C'est la brique moteur de la vue synoptique
//  série/parallèle.
//
//  Le plugin ne traite aucun audio — il est purement structurel. Tout se joue à la
//  construction du graphe : createPluginNodeForList reconnaît l'interface
//  te::ParallelPluginBlock et déplie le plugin en SummingNode { branche… }, chaque branche
//  partant d'un ConnectedNode sur l'entrée partagée. SummingNode::createLatencyNodes()
//  égalise ensuite les branches entre elles.
//
//  Latence : la branche la plus longue (somme série de chacune, récursif). Elle DOIT être
//  déclarée, sinon la PDC du ContainerClip — qui lit son contenu en avance de la latence de
//  sa plugin-list — sous-compense sans rien dire.
//
//  État : un enfant <BRANCH> par branche, dont les enfants <PLUGIN> sont la chaîne série de
//  cette branche. La PluginList de chaque branche est bâtie par-dessus, à la demande.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjParallelBlockPlugin  : public Plugin,
                                public ParallelPluginBlock
{
public:
    ObjParallelBlockPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        // N.B. pas de state.addListener : Plugin s'y enregistre déjà, on surcharge simplement
        // valueTreeChildAdded/Removed.
        rebuildBranchLists();
    }

    ~ObjParallelBlockPlugin() override                      { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjParallelBlockPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Parallel Block"); }
    static const char* xmlTypeName;

    /// Type d'arbre d'une branche. Celui que DÉCLARE l'interface moteur : c'est lui qui autorise
    /// une PluginList à s'initialiser dessus (@see PluginList::initialise, patch moteur 0018),
    /// donc la même chaîne écrite ici de son côté n'aurait été qu'une coïncidence.
    static const juce::Identifier& branchType()             { return ParallelPluginBlock::branchTreeType; }

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    /// Nombre de branches. En poser 0 rend le bloc transparent, 1 le remet en série —
    /// dans les deux cas createNodeForParallelBlock évite le SummingNode.
    int getNumBranches() const                              { return (int) branchLists.size(); }

    /// PluginList d'une branche, ou nullptr hors bornes.
    PluginList* getBranch (int index) const
    {
        return juce::isPositiveAndBelow (index, (int) branchLists.size())
                 ? branchLists[(size_t) index].get() : nullptr;
    }

    /// Ajoute une branche vide et renvoie sa PluginList.
    PluginList* addBranch()
    {
        state.appendChild (juce::ValueTree (branchType()), getUndoManager());
        return branchLists.empty() ? nullptr : branchLists.back().get();
    }

    /// Retire une branche et tous ses plugins.
    void removeBranch (int index)
    {
        if (auto v = state.getChildWithName (branchType()); v.isValid())
            if (auto child = branchTreeAt (index); child.isValid())
                state.removeChild (child, getUndoManager());
    }

    //==============================================================================
    std::vector<PluginList*> getParallelBranches() override
    {
        std::vector<PluginList*> branches;

        for (auto& l : branchLists)
            branches.push_back (l.get());

        return branches;
    }

    double getLatencySeconds() override
    {
        return ParallelPluginBlock::getMaxBranchLatencySeconds (*this);
    }

    /// Les plugins de branche ne sont pas dans la plugin-list hôte : personne d'autre ne les
    /// initialiserait. Sans ça leur latence vaudrait 0 au premier build du graphe — et la
    /// lecture anticipée du container serait construite sur une valeur fausse.
    void initialiseFully() override
    {
        Plugin::initialiseFully();

        for (auto& l : branchLists)
            for (auto p : *l)
                p->initialiseFully();
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Parallel Block"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Par"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (2, numInputs); }
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    // Purement structurel : le dépliage a lieu à la construction du nœud, ce plugin-ci n'est
    // jamais traversé par l'audio. Si on l'appelle quand même (rendu d'une liste non dépliée),
    // laisser passer est le comportement juste.
    void applyToBuffer (const PluginRenderContext&) override {}

    void restorePluginStateFromValueTree (const juce::ValueTree&) override {}

private:
    //==============================================================================
    std::vector<std::unique_ptr<PluginList>> branchLists;

    juce::ValueTree branchTreeAt (int index) const
    {
        int seen = 0;

        for (int i = 0; i < state.getNumChildren(); ++i)
            if (auto c = state.getChild (i); c.hasType (branchType()))
                if (seen++ == index)
                    return c;

        return {};
    }

    // Les PluginList sont reconstruites d'un bloc : elles ne sont que des vues sur les
    // sous-arbres <BRANCH>, et une reconstruction ne survient qu'à l'édition de la structure
    // (pas en lecture). Le graphe est reconstruit derrière de toute façon.
    void rebuildBranchLists()
    {
        branchLists.clear();

        for (int i = 0; i < state.getNumChildren(); ++i)
        {
            auto c = state.getChild (i);

            if (! c.hasType (branchType()))
                continue;

            auto list = std::make_unique<PluginList> (edit);
            list->setTrackAndClip (getOwnerTrack(), getOwnerClip());
            list->initialise (c);
            branchLists.push_back (std::move (list));
        }
    }

    void valueTreeChildAdded (juce::ValueTree& parent, juce::ValueTree& child) override
    {
        if (parent == state && child.hasType (branchType()))
            rebuildBranchLists();

        Plugin::valueTreeChildAdded (parent, child);
    }

    void valueTreeChildRemoved (juce::ValueTree& parent, juce::ValueTree& child, int index) override
    {
        if (parent == state && child.hasType (branchType()))
            rebuildBranchLists();

        Plugin::valueTreeChildRemoved (parent, child, index);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjParallelBlockPlugin)
};

inline const char* ObjParallelBlockPlugin::xmlTypeName = "objParallelBlock";

}} // namespace tracktion { inline namespace engine }
